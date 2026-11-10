import Foundation

/// OpenAI Chat Completions protocol — OpenAI, Gemini, OpenRouter, LM Studio, Ollama, vLLM, llama.cpp…
struct OpenAICompatibleClient: LLMClient {
    let provider: ProviderConfig
    let apiKey: String

    private var isOfficialOpenAI: Bool { provider.baseURL.contains("api.openai.com") }

    private func makeRequest(path: String, method: String = "GET") throws -> URLRequest {
        var req = URLRequest(url: try HTTP.url(provider, path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if provider.preset == .openRouter {
            req.setValue("https://github.com/quizsnapper", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("QuizSnapper", forHTTPHeaderField: "X-Title")
        }
        return req
    }

    func listModels() async throws -> [ModelInfo] {
        if provider.preset.requiresKey && apiKey.isEmpty { throw LLMError.missingAPIKey(provider.name) }
        do {
            let req = try makeRequest(path: "/models")
            let (data, response) = try await HTTP.session(timeout: 20).data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw LLMError.http(http.statusCode, HTTP.errorMessage(from: data))
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let items = json?["data"] as? [[String: Any]] ?? []
            return items.compactMap { item in
                guard var id = item["id"] as? String else { return nil }
                // Gemini returns "models/gemini-…"; the chat endpoint wants the bare id.
                if provider.preset == .gemini, id.hasPrefix("models/") { id = String(id.dropFirst(7)) }
                return ModelInfo(id: id, displayName: item["name"] as? String, maxOutputTokens: nil)
            }.sorted { $0.id < $1.id }
        } catch {
            throw HTTP.friendly(error, provider: provider)
        }
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if provider.preset.requiresKey && apiKey.isEmpty { throw LLMError.missingAPIKey(provider.name) }
                    guard !request.model.isEmpty else { throw LLMError.missingModel }

                    // Some servers reject optional fields (reasoning_effort, max_tokens vs max_completion_tokens,
                    // stream_options). Retry with a simpler body instead of failing.
                    var options = BodyOptions(useMaxCompletionTokens: isOfficialOpenAI)
                    var bytes: URLSession.AsyncBytes!
                    for attempt in 0..<4 {
                        var req = try makeRequest(path: "/chat/completions", method: "POST")
                        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        req.httpBody = try JSONSerialization.data(withJSONObject: body(for: request, options: options))
                        let (b, response) = try await HTTP.session(timeout: provider.timeoutSeconds).bytes(for: req)
                        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { bytes = b; break }
                        let message = await HTTP.errorMessage(from: b)
                        let lower = message.lowercased()
                        guard (400...422).contains(http.statusCode), attempt < 3 else {
                            throw LLMError.http(http.statusCode, message)
                        }
                        if !options.dropEffort && (lower.contains("reasoning_effort") || lower.contains("reasoning")) && request.effort != .auto {
                            options.dropEffort = true
                        } else if lower.contains("max_completion_tokens") && !options.useMaxCompletionTokens {
                            options.useMaxCompletionTokens = true
                        } else if lower.contains("max_tokens") && options.useMaxCompletionTokens == false && !options.dropMaxTokens {
                            options.useMaxCompletionTokens = true
                        } else if lower.contains("stream_options") && !options.dropStreamOptions {
                            options.dropStreamOptions = true
                        } else if (lower.contains("max_tokens") || lower.contains("max_completion_tokens")) && !options.dropMaxTokens {
                            options.dropMaxTokens = true
                        } else {
                            throw LLMError.http(http.statusCode, message)
                        }
                        Log.write("\(provider.name) rejected a parameter (\(message.prefix(160))) — retrying with \(options)")
                    }

                    var splitter = ThinkTagSplitter()
                    var gotEvent = false
                    var sawStop = false
                    var raw = ""
                    func emit(_ text: String) {
                        for piece in splitter.feed(text) {
                            continuation.yield(piece.isThinking ? .reasoning(piece.text) : .text(piece.text))
                        }
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else {
                            if !gotEvent && raw.count < 400_000 { raw += line + "\n" }
                            continue
                        }
                        gotEvent = true
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { sawStop = true; break }
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let err = event["error"], !(err is NSNull) {
                            let message = (err as? [String: Any])?["message"] as? String ?? "\(err)"
                            throw LLMError.api(message)
                        }
                        if let usage = event["usage"] as? [String: Any] {
                            continuation.yield(.usage(input: usage["prompt_tokens"] as? Int,
                                                      output: usage["completion_tokens"] as? Int))
                        }
                        guard let choice = (event["choices"] as? [[String: Any]])?.first else { continue }
                        if let delta = choice["delta"] as? [String: Any] {
                            // Some servers send both keys with the same text — use the first one present.
                            if let r = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !r.isEmpty {
                                continuation.yield(.reasoning(r))
                            }
                            // Local reasoning models (Qwen, DeepSeek…) inline <think>…</think>.
                            if let text = delta["content"] as? String, !text.isEmpty { emit(text) }
                        }
                        if let finish = choice["finish_reason"] as? String {
                            sawStop = true
                            continuation.yield(.finished(stopReason: finish == "length" ? "max_tokens" : finish))
                        }
                    }
                    for piece in splitter.flush() {
                        continuation.yield(piece.isThinking ? .reasoning(piece.text) : .text(piece.text))
                    }

                    if gotEvent && !sawStop {
                        throw LLMError.connection("The connection closed before the answer finished.")
                    }
                    // Servers that ignore "stream": true answer with a single JSON object.
                    if !gotEvent, let data = raw.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let err = json["error"], !(err is NSNull) {
                            throw LLMError.api((err as? [String: Any])?["message"] as? String ?? "\(err)")
                        }
                        let choice = (json["choices"] as? [[String: Any]])?.first
                        let message = choice?["message"] as? [String: Any]
                        if let r = (message?["reasoning_content"] as? String) ?? (message?["reasoning"] as? String), !r.isEmpty {
                            continuation.yield(.reasoning(r))
                        }
                        if let text = message?["content"] as? String { emit(text) }
                        for piece in splitter.flush() {
                            continuation.yield(piece.isThinking ? .reasoning(piece.text) : .text(piece.text))
                        }
                        if let usage = json["usage"] as? [String: Any] {
                            continuation.yield(.usage(input: usage["prompt_tokens"] as? Int, output: usage["completion_tokens"] as? Int))
                        }
                        let finish = choice?["finish_reason"] as? String
                        continuation.yield(.finished(stopReason: finish == "length" ? "max_tokens" : finish))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: HTTP.friendly(error, provider: provider))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct BodyOptions: CustomStringConvertible {
        var useMaxCompletionTokens: Bool
        var dropEffort = false
        var dropMaxTokens = false
        var dropStreamOptions = false
        var description: String {
            "maxCompletionTokens=\(useMaxCompletionTokens) dropEffort=\(dropEffort) dropMaxTokens=\(dropMaxTokens) dropStreamOptions=\(dropStreamOptions)"
        }
    }

    private func body(for request: LLMRequest, options: BodyOptions) -> [String: Any] {
        var content: [[String: Any]] = []
        let prompt = request.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        content.append(["type": "text", "text": prompt.isEmpty ? "Answer the question in the screenshot(s)." : prompt])
        for (idx, image) in request.images.enumerated() {
            if request.images.count > 1 {
                content.append(["type": "text", "text": "Image \(idx + 1) of \(request.images.count):"])
            }
            content.append(["type": "image_url", "image_url": ["url": image.dataURL]])
        }

        var messages: [[String: Any]] = []
        let system = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": content])

        var body: [String: Any] = ["model": request.model, "messages": messages, "stream": true]
        if let max = request.maxTokens, !options.dropMaxTokens {
            body[options.useMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"] = max
        }
        let effort = request.effort.clamped(to: .openAICompatible)
        if effort != .auto && !options.dropEffort {
            if provider.preset == .openRouter {
                body["reasoning"] = ["effort": effort == .minimal ? "low" : effort.rawValue]
            } else {
                body["reasoning_effort"] = effort.rawValue
            }
        }
        if (isOfficialOpenAI || provider.preset == .openRouter) && !options.dropStreamOptions {
            body["stream_options"] = ["include_usage": true]
        }
        return body
    }
}

struct ThinkPiece { var text: String; var isThinking: Bool }

/// Splits `<think>…</think>` out of streamed text, even when a tag is cut across two chunks.
struct ThinkTagSplitter {
    private var inThink = false
    private var pending = ""

    mutating func feed(_ chunk: String) -> [ThinkPiece] {
        var text = pending + chunk
        pending = ""
        var pieces: [ThinkPiece] = []
        while !text.isEmpty {
            let tag = inThink ? "</think>" : "<think>"
            if let range = text.range(of: tag) {
                let before = String(text[..<range.lowerBound])
                if !before.isEmpty { pieces.append(ThinkPiece(text: before, isThinking: inThink)) }
                inThink.toggle()
                text = String(text[range.upperBound...])
                continue
            }
            // Hold back a tail that could be the start of a tag ("<thi").
            var keep = 0
            for n in stride(from: min(tag.count - 1, text.count), through: 1, by: -1) where tag.hasPrefix(String(text.suffix(n))) {
                keep = n
                break
            }
            let emit = String(text.dropLast(keep))
            if !emit.isEmpty { pieces.append(ThinkPiece(text: emit, isThinking: inThink)) }
            pending = String(text.suffix(keep))
            break
        }
        return pieces
    }

    mutating func flush() -> [ThinkPiece] {
        defer { pending = "" }
        return pending.isEmpty ? [] : [ThinkPiece(text: pending, isThinking: inThink)]
    }
}
