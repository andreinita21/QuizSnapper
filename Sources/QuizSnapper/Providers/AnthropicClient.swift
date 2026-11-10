import Foundation

/// Claude Messages API (raw HTTP + SSE streaming).
struct AnthropicClient: LLMClient {
    let provider: ProviderConfig
    let apiKey: String

    static let apiVersion = "2026-10-21"
    static let fallbackMaxTokens = 64_000

    private func makeRequest(path: String, method: String = "GET") throws -> URLRequest {
        var req = URLRequest(url: try HTTP.url(provider, path))
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        return req
    }

    func listModels() async throws -> [ModelInfo] {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(provider.name) }
        let req = try makeRequest(path: "/models?limit=1000")
        let (data, response) = try await HTTP.session(timeout: 30).data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LLMError.http(http.statusCode, HTTP.errorMessage(from: data))
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["data"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return ModelInfo(id: id, displayName: item["display_name"] as? String,
                             maxOutputTokens: item["max_tokens"] as? Int)
        }
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(provider.name) }
                    guard !request.model.isEmpty else { throw LLMError.missingModel }

                    // Older / smaller models reject effort or thinking, and every model has an output cap.
                    // Retry once with a simpler request instead of failing the snap.
                    var options = BodyOptions()
                    var bytes: URLSession.AsyncBytes!
                    for attempt in 0..<3 {
                        var req = try makeRequest(path: "/messages", method: "POST")
                        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
                        req.httpBody = try JSONSerialization.data(withJSONObject: body(for: request, options: options))
                        let (b, response) = try await HTTP.session(timeout: provider.timeoutSeconds).bytes(for: req)
                        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { bytes = b; break }
                        let message = await HTTP.errorMessage(from: b)
                        let lower = message.lowercased()
                        if http.statusCode == 400, attempt < 2, !options.stripReasoning,
                           lower.contains("effort") || lower.contains("thinking") || lower.contains("output_config") {
                            Log.write("Claude rejected effort/thinking for \(request.model) — retrying without: \(message)")
                            options.stripReasoning = true
                            continue
                        }
                        if http.statusCode == 400, attempt < 2, options.maxTokens == nil, lower.contains("max_tokens") {
                            let allowed = Self.allowedMaxTokens(in: message) ?? 32_000
                            Log.write("Claude rejected max_tokens — retrying with \(allowed)")
                            options.maxTokens = allowed
                            continue
                        }
                        throw LLMError.http(http.statusCode, message)
                    }

                    var gotEvent = false
                    var sawStop = false
                    var raw = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else {
                            if !gotEvent && raw.count < 400_000 { raw += line + "\n" }
                            continue
                        }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = event["type"] as? String else { continue }
                        gotEvent = true

                        switch type {
                        case "message_start":
                            let usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any]
                            let input = (usage?["input_tokens"] as? Int ?? 0)
                                + (usage?["cache_read_input_tokens"] as? Int ?? 0)
                                + (usage?["cache_creation_input_tokens"] as? Int ?? 0)
                            continuation.yield(.usage(input: input, output: nil))
                        case "content_block_delta":
                            guard let delta = event["delta"] as? [String: Any] else { continue }
                            switch delta["type"] as? String {
                            case "text_delta":
                                if let text = delta["text"] as? String { continuation.yield(.text(text)) }
                            case "thinking_delta":
                                if let text = delta["thinking"] as? String, !text.isEmpty {
                                    continuation.yield(.reasoning(text))
                                }
                            default: break
                            }
                        case "message_delta":
                            let usage = event["usage"] as? [String: Any]
                            if let out = usage?["output_tokens"] as? Int {
                                continuation.yield(.usage(input: nil, output: out))
                            }
                            if let stop = (event["delta"] as? [String: Any])?["stop_reason"] as? String {
                                if stop == "refusal" {
                                    throw LLMError.api("The model declined to answer this request (refusal).")
                                }
                                sawStop = true
                                continuation.yield(.finished(stopReason: stop))
                            }
                        case "message_stop":
                            sawStop = true
                        case "error":
                            let message = (event["error"] as? [String: Any])?["message"] as? String ?? "Stream error"
                            throw LLMError.api(message)
                        default:
                            break
                        }
                    }
                    if gotEvent && !sawStop {
                        throw LLMError.connection("The connection closed before the answer finished.")
                    }
                    // A proxy / gateway may ignore "stream": true and return one JSON message.
                    if !gotEvent, let data = raw.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let err = json["error"] as? [String: Any] {
                            throw LLMError.api(err["message"] as? String ?? "Unknown error")
                        }
                        for block in json["content"] as? [[String: Any]] ?? [] {
                            if let t = block["text"] as? String { continuation.yield(.text(t)) }
                            if let t = block["thinking"] as? String, !t.isEmpty { continuation.yield(.reasoning(t)) }
                        }
                        let usage = json["usage"] as? [String: Any]
                        continuation.yield(.usage(input: usage?["input_tokens"] as? Int, output: usage?["output_tokens"] as? Int))
                        continuation.yield(.finished(stopReason: json["stop_reason"] as? String))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: HTTP.friendly(error, provider: provider))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct BodyOptions {
        var stripReasoning = false
        var maxTokens: Int?
    }

    /// Pulls the allowed maximum out of messages like "max_tokens: 200000 > 64000, which is the maximum…".
    static func allowedMaxTokens(in message: String) -> Int? {
        guard let range = message.range(of: #">\s*(\d{3,7})"#, options: .regularExpression) else { return nil }
        return Int(message[range].filter(\.isNumber))
    }

    private func body(for request: LLMRequest, options: BodyOptions = BodyOptions()) -> [String: Any] {
        var content: [[String: Any]] = request.images.map { image in
            ["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": image.base64]]
        }
        if request.images.count > 1 {
            // Label images so the model keeps their order straight.
            content = request.images.enumerated().flatMap { idx, image -> [[String: Any]] in
                [["type": "text", "text": "Image \(idx + 1) of \(request.images.count):"],
                 ["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": image.base64]]]
            }
        }
        let prompt = request.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        content.append(["type": "text", "text": prompt.isEmpty ? "Answer the question in the screenshot(s)." : prompt])

        let modelMax = provider.cachedModels.first { $0.id == request.model }?.maxOutputTokens
        var maxTokens = request.maxTokens ?? modelMax ?? Self.fallbackMaxTokens
        if let modelMax { maxTokens = min(maxTokens, modelMax) }
        if let forced = options.maxTokens { maxTokens = min(maxTokens, forced) }

        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": [["role": "user", "content": content]],
        ]
        let system = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { body["system"] = system }

        guard !options.stripReasoning else { return body }
        let effort = request.effort.clamped(to: .anthropic)
        if effort != .auto {
            body["output_config"] = ["effort": effort.rawValue]
        }
        if request.showReasoning {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
        } else if effort != .auto {
            body["thinking"] = ["type": "adaptive"]
        }
        return body
    }
}
