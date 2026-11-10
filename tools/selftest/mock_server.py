"""Tiny mock of the Anthropic and OpenAI-compatible APIs for QuizSnapper's self-test.
The model name selects the behaviour."""
import json, http.server, sys

def sse(events):
    return "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events)

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, body, ctype="application/json"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send(200, json.dumps({"data": [{"id": "mock-model", "display_name": "Mock", "max_tokens": 64000},
                                            {"id": "models/gemini-x"}]}))

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        model = req.get("model", "")
        if self.path.endswith("/messages"):
            if self.headers.get("x-api-key") == "bad":
                return self.send(401, '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}')
            if model == "reject-effort" and ("output_config" in req or "thinking" in req):
                return self.send(400, '{"type":"error","error":{"type":"invalid_request_error","message":"effort is not supported on this model"}}')
            if model == "small-cap" and req["max_tokens"] > 8192:
                return self.send(400, json.dumps({"type": "error", "error": {"type": "invalid_request_error",
                    "message": f"max_tokens: {req['max_tokens']} > 8192, which is the maximum allowed number of output tokens"}}))
            if model == "nonstream":
                return self.send(200, json.dumps({"content": [{"type": "text", "text": "C\nPlain JSON."}],
                                                  "usage": {"input_tokens": 5, "output_tokens": 3}, "stop_reason": "end_turn"}))
            if model == "cutoff":
                return self.send(200, sse([{"type": "message_start", "message": {"usage": {"input_tokens": 1}}},
                    {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "B\nHalf"}}]), "text/event-stream")
            n = sum(1 for c in req["messages"][0]["content"] if c["type"] == "image")
            body = sse([{"type": "message_start", "message": {"usage": {"input_tokens": 1200}}},
                        {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "Option B fits."}},
                        {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "B\n"}},
                        {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": f"Saw {n} images."}},
                        {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 42}},
                        {"type": "message_stop"}])
            return self.send(200, body, "text/event-stream")
        # OpenAI-compatible
        if model == "needs-mct" and "max_tokens" in req:
            return self.send(400, '{"error":{"message":"Unsupported parameter: \'max_tokens\' is not supported with this model. Use \'max_completion_tokens\' instead."}}')
        if model == "no-effort" and "reasoning_effort" in req:
            return self.send(400, '{"error":{"message":"Unrecognized request argument supplied: reasoning_effort"}}')
        if model == "nonstream":
            return self.send(200, json.dumps({"choices": [{"message": {"content": "<think>hmm</think>D\nNo SSE."}, "finish_reason": "stop"}],
                                              "usage": {"prompt_tokens": 4, "completion_tokens": 2}}))
        if model == "cutoff":
            return self.send(200, "data: " + json.dumps({"choices": [{"delta": {"content": "A\nHal"}, "finish_reason": None}]}) + "\n\n", "text/event-stream")
        if model == "nullerror":
            return self.send(200, "data: " + json.dumps({"error": None, "choices": [{"delta": {"content": "C", "reasoning": "r", "reasoning_content": "r"}, "finish_reason": "stop"}]}) + "\n\ndata: [DONE]\n\n", "text/event-stream")
        chunks = ["<thi", "nk>pondering", "</th", "ink>A, C\n", "Both are prime."]
        out = "".join("data: " + json.dumps({"choices": [{"delta": {"content": c}, "finish_reason": None}]}) + "\n\n" for c in chunks)
        out += "data: " + json.dumps({"choices": [{"delta": {}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 9, "completion_tokens": 7}}) + "\n\n"
        out += "data: [DONE]\n\n"
        self.send(200, out, "text/event-stream")

http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
