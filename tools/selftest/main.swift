// QuizSnapper self-test: provider clients against a mock server + pure logic. Run via tools/selftest/run.sh
import AppKit
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if cond { print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name) \(detail())") }
}

struct Result { var text = "", reasoning = "", stop: String?, input: Int?, output: Int?, error: String? }

func run(_ p: ProviderConfig, key: String = "k", model: String = "mock-model", effort: Effort = .high,
         maxTokens: Int? = nil, images: Int = 2) async -> Result {
    let c = LLMClientFactory.make(for: p, apiKey: key)
    let img = EncodedImage(data: Data([1, 2, 3]), mediaType: "image/jpeg")
    let req = LLMRequest(model: model, systemPrompt: "sys", userPrompt: "q", images: Array(repeating: img, count: images),
                         effort: effort, maxTokens: maxTokens, showReasoning: true)
    var r = Result()
    do {
        for try await e in c.stream(req) {
            switch e {
            case .text(let t): r.text += t
            case .reasoning(let t): r.reasoning += t
            case .usage(let i, let o): if let i { r.input = i }; if let o { r.output = o }
            case .finished(let s): r.stop = s
            }
        }
    } catch { r.error = error.localizedDescription }
    return r
}

let port = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "8765"
var anthropic = ProviderConfig(name: "A", preset: .anthropic, baseURL: "http://127.0.0.1:\(port)/v1")
anthropic.cachedModels = [ModelInfo(id: "mock-model", displayName: nil, maxOutputTokens: 64000)]
let lm = ProviderConfig(name: "LM", preset: .lmStudio, baseURL: "127.0.0.1:\(port)")   // no scheme, no /v1
let openai = ProviderConfig(name: "O", preset: .custom, baseURL: "http://127.0.0.1:\(port)/v1/chat/completions")
let dead = ProviderConfig(name: "Dead", preset: .ollama, baseURL: "http://127.0.0.1:1/v1")

print("Anthropic")
var r = await run(anthropic)
check(r.text == "B\nSaw 2 images.", "streams text", r.text.debugDescription + " " + (r.error ?? ""))
check(r.reasoning == "Option B fits.", "streams reasoning")
check(r.input == 1200 && r.output == 42 && r.stop == "end_turn", "usage + stop reason")
r = await run(anthropic, key: "bad")
check(r.error?.contains("401") == true, "bad key → readable 401", r.error ?? "nil")
r = await run(anthropic, model: "reject-effort")
check(r.error == nil && r.text.hasPrefix("B"), "retries without effort/thinking", r.error ?? "")
r = await run(anthropic, model: "small-cap", maxTokens: nil)
check(r.error == nil && r.text.hasPrefix("B"), "retries with the model's max_tokens", r.error ?? "")
r = await run(anthropic, model: "nonstream")
check(r.text == "C\nPlain JSON." && r.output == 3, "handles non-streamed JSON reply", r.text.debugDescription + (r.error ?? ""))
r = await run(anthropic, model: "cutoff")
check(r.text == "B\nHalf" && r.error?.contains("closed before") == true, "cut-off stream keeps partial text + reports error", r.text.debugDescription + " " + (r.error ?? "nil"))
check(AnthropicClient.allowedMaxTokens(in: "max_tokens: 128000 > 64000, which is the maximum") == 64000, "parses allowed max_tokens")

print("OpenAI-compatible")
r = await run(lm, effort: .auto)
check(r.text == "A, C\nBoth are prime.", "think tags split across chunks", r.text.debugDescription + (r.error ?? ""))
check(r.reasoning == "pondering", "think content → reasoning", r.reasoning.debugDescription)
check(r.input == 9 && r.output == 7, "usage")
r = await run(openai, model: "needs-mct", maxTokens: 500)
check(r.error == nil && r.text.hasPrefix("A"), "retries with max_completion_tokens", r.error ?? "")
r = await run(openai, model: "no-effort", effort: .high)
check(r.error == nil && r.text.hasPrefix("A"), "retries without reasoning_effort", r.error ?? "")
r = await run(openai, model: "nonstream")
check(r.text == "D\nNo SSE." && r.reasoning == "hmm", "handles non-streamed JSON reply", r.text.debugDescription + (r.error ?? ""))
r = await run(openai, model: "cutoff", effort: .auto)
check(r.text == "A\nHal" && r.error?.contains("closed before") == true, "cut-off stream keeps partial text + reports error", r.text.debugDescription + " " + (r.error ?? "nil"))
r = await run(openai, model: "nullerror", effort: .auto)
check(r.error == nil && r.text == "C" && r.reasoning == "r", "\"error\": null ignored, reasoning not doubled", (r.error ?? "") + r.reasoning)
r = await run(dead)
check(r.error?.contains("Is the local server running") == true, "unreachable local server message", r.error ?? "nil")
let models = (try? await LLMClientFactory.make(for: lm, apiKey: "").listModels())?.map(\.id) ?? []
check(models.contains("mock-model"), "lists models", "\(models)")

print("URL normalization")
func norm(_ preset: ProviderPreset, _ url: String) -> String { HTTP.normalizedBase(ProviderConfig(name: "x", preset: preset, baseURL: url)) }
check(norm(.lmStudio, "localhost:1234") == "http://localhost:1234/v1", "adds scheme and /v1", norm(.lmStudio, "localhost:1234"))
check(norm(.custom, "http://h:8080/v1/chat/completions/") == "http://h:8080/v1", "strips endpoint path")
check(norm(.gemini, "https://generativelanguage.googleapis.com/v1beta/openai") == "https://generativelanguage.googleapis.com/v1beta/openai", "keeps custom paths")
check(norm(.openAI, "api.openai.com") == "https://api.openai.com/v1", "https for remote hosts")

print("Answer parsing")
let cases: [(String, String?)] = [
    ("B\nBecause photosynthesis.", "B"), ("**A, C** — both", "A,C"), ("1: B\n2: A, D", "1:B 2:A,D"),
    ("The correct answer is D because", "D"), ("No quiz found", nil), ("Because it is", nil),
    ("A function is a mapping", nil), ("I think it's B", nil), ("(C) Paris", "C"), ("A. Paris", "A"),
    ("A and C", "A,C"), ("B - reason", "B"), ("Răspuns: C", "C"), ("Answer: **B**", "B"), ("D", "D"),
    ("A) 42", "A"), ("Q1 - B\nQ2 - C", "1:B 2:C"),
]
for (input, expected) in cases {
    let got = AnswerParser.letters(from: input)
    check(got == expected, "\(input.debugDescription) → \(expected ?? "nil")", "got \(got ?? "nil")")
}
check(AnswerParser.explanation(of: "B\nBecause.") == "Because.", "explanation drops letter line")

print("Answer shape (letters vs. fill-in)")
let shapes: [(String, AnswerShape)] = [
    ("B\nBecause photosynthesis.", .letters("B")),
    ("A, C", .letters("A,C")),
    ("1: B\n2: A, D", .letters("1:B 2:A,D")),
    ("FILL: chmod 755; /etc/passwd; 3", .fillIn(["chmod 755", "/etc/passwd", "3"])),
    ("fill-in: ls -la ; grep -r\nBoth list files.", .fillIn(["ls -la", "grep -r"])),
    ("FILL: 42", .fillIn(["42"])),
    ("ls -la; chmod 755; /etc/hosts", .fillIn(["ls -la", "chmod 755", "/etc/hosts"])),
    ("1. chmod 755\n2) /etc/passwd\n3: kill -9", .fillIn(["chmod 755", "/etc/passwd", "kill -9"])),
    ("B; because it floats", .letters("B")),            // letter + justification, not two boxes
    ("Photosynthesis happens in the chloroplasts; respiration in the mitochondria", .none),
    ("No quiz found", .none),
    ("FILL: A; 3", .fillIn(["A", "3"])),                // marker wins over letter parsing
]
for (input, expected) in shapes {
    let got = AnswerParser.shape(of: input)
    check(got == expected, "\(input.debugDescription) → \(expected)", "got \(got)")
}
check(AnswerShape.fillIn(["a", "b"]).clipboardText == "a; b", "fill-in values join with \"; \"")
check(AnswerShape.letters("B").clipboardText == nil && !AnswerShape.letters("B").isFillIn, "letters never go to the clipboard")
check(AnswerParser.explanation(of: "FILL: a; b\nBoth are flags.") == "Both are flags.", "explanation drops the fill-in line")

print("Effort + model picking")
check(Effort.max.clamped(to: .openAICompatible) == .high && Effort.minimal.clamped(to: .anthropic) == .low, "effort clamps per provider")
let picked = [ModelInfo(id: "text-embedding-nomic", displayName: nil, maxOutputTokens: nil),
              ModelInfo(id: "llama-3.1-8b", displayName: nil, maxOutputTokens: nil),
              ModelInfo(id: "qwen2.5-vl-7b", displayName: nil, maxOutputTokens: nil)].preferredForVision?.id
check(picked == "qwen2.5-vl-7b", "prefers a vision model", picked ?? "nil")

print("Image encoding")
func noise(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let buf = ctx.data!.bindMemory(to: UInt32.self, capacity: w * h)
    for i in 0..<(w * h) { buf[i] = UInt32.random(in: 0...UInt32.max) | 0xFF00_0000 }
    return ctx.makeImage()!
}
var settings = AppSettings()
settings.imageFormat = .png
settings.imageMaxDimension = 4096
let big = noise(4000, 3000)
let enc = ImageEncoder.encode(big, settings: settings)
check(enc != nil && enc!.data.count <= ImageEncoder.maxBytes, "noisy 4000×3000 PNG shrinks under the size limit", "\(enc?.data.count ?? -1) bytes")
let many = ImageEncoder.encodeAll(Array(repeating: noise(2600, 1600), count: 21), settings: settings)
let dims = many.compactMap { NSBitmapImageRep(data: $0.data) }.map { max($0.pixelsWide, $0.pixelsHigh) }
check(many.count == 21 && dims.allSatisfy { $0 <= 2000 }, ">20 images are capped at 2000 px", "\(dims.max() ?? -1)")

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
