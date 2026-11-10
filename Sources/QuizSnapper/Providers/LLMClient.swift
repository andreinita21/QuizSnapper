import Foundation

struct EncodedImage {
    var data: Data
    var mediaType: String
    var base64: String { data.base64EncodedString() }
    var dataURL: String { "data:\(mediaType);base64,\(base64)" }
}

struct LLMRequest {
    var model: String
    var systemPrompt: String
    var userPrompt: String
    var images: [EncodedImage]
    var effort: Effort
    /// nil = unlimited (use the model's maximum / omit the limit).
    var maxTokens: Int?
    var showReasoning: Bool
}

enum StreamEvent {
    case text(String)
    case reasoning(String)
    case usage(input: Int?, output: Int?)
    case finished(stopReason: String?)
}

enum LLMError: LocalizedError {
    case missingAPIKey(String)
    case missingModel
    case invalidURL(String)
    case http(Int, String)
    case api(String)
    case noProvider
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let name): return "No API key for \(name). Add it in Settings → Providers."
        case .missingModel: return "This profile has no model selected. Pick one in Settings → Profiles."
        case .invalidURL(let url): return "Invalid base URL: \(url)"
        case .http(let code, let message): return "HTTP \(code): \(message)"
        case .api(let message): return message
        case .noProvider: return "This profile isn't linked to a provider. Pick one in Settings → Profiles."
        case .connection(let message): return message
        }
    }
}

protocol LLMClient {
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error>
    func listModels() async throws -> [ModelInfo]
}

enum LLMClientFactory {
    static func make(for provider: ProviderConfig, apiKey: String?) -> LLMClient {
        switch provider.kind {
        case .anthropic: return AnthropicClient(provider: provider, apiKey: apiKey ?? "")
        case .openAICompatible: return OpenAICompatibleClient(provider: provider, apiKey: apiKey ?? "")
        }
    }
}

// MARK: - HTTP helpers

enum HTTP {
    private static var sessions: [Int: URLSession] = [:]
    private static let lock = NSLock()

    /// One shared session per timeout value (sessions are expensive and must not be created per request).
    static func session(timeout: Double) -> URLSession {
        let key = Int(max(timeout, 10))
        lock.lock(); defer { lock.unlock() }
        if let s = sessions[key] { return s }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Double(key)
        config.timeoutIntervalForResource = max(Double(key) * 4, 600)
        config.waitsForConnectivity = false
        let s = URLSession(configuration: config)
        sessions[key] = s
        return s
    }

    /// Forgiving base-URL handling: accepts "localhost:1234", "http://host:11434", ".../v1/chat/completions"…
    static func normalizedBase(_ provider: ProviderConfig) -> String {
        var base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = provider.preset.defaultBaseURL }
        if !base.contains("://") {
            let local = base.hasPrefix("localhost") || base.hasPrefix("127.") || base.hasPrefix("0.0.0.0")
                || base.hasPrefix("192.168.") || base.hasPrefix("10.") || base.hasSuffix(".local")
            base = (local ? "http://" : "https://") + base
        }
        while base.hasSuffix("/") { base.removeLast() }
        for suffix in ["/chat/completions", "/completions", "/messages", "/models"] where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
        }
        while base.hasSuffix("/") { base.removeLast() }
        if let comps = URLComponents(string: base), comps.path.isEmpty || comps.path == "/" {
            base += "/v1"
        }
        return base
    }

    static func url(_ provider: ProviderConfig, _ path: String) throws -> URL {
        let base = normalizedBase(provider)
        guard let url = URL(string: base + path), let host = url.host, !host.isEmpty else {
            throw LLMError.invalidURL(provider.baseURL)
        }
        return url
    }

    /// Reads the full body of a failed streaming response and extracts a readable message.
    static func errorMessage(from bytes: URLSession.AsyncBytes) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > 64_000 { break }
            }
        } catch {}
        return errorMessage(from: data)
    }

    static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
            if let msg = json["error"] as? String { return msg }
            if let msg = json["message"] as? String { return msg }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? "Unknown error" : String(text.prefix(500))
    }

    static func friendly(_ error: Error, provider: ProviderConfig) -> Error {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return error }
        switch ns.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            if provider.preset.isLocal {
                return LLMError.connection("Can't reach \(provider.name) at \(provider.baseURL). Is the local server running?")
            }
            return LLMError.connection("Can't connect to \(provider.baseURL).")
        case NSURLErrorTimedOut:
            return LLMError.connection("\(provider.name) timed out. Increase the timeout in Settings → Providers.")
        case NSURLErrorNotConnectedToInternet:
            return LLMError.connection("You're offline.")
        default:
            return error
        }
    }
}
