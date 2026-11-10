import Foundation

// MARK: - Providers

enum ProviderKind: String, Codable {
    case anthropic
    case openAICompatible
}

/// A provider "preset" decides the wire protocol, default URL and UI hints.
enum ProviderPreset: String, Codable, CaseIterable, Identifiable {
    case anthropic, openAI, gemini, openRouter, lmStudio, ollama, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .lmStudio: return "LM Studio (local)"
        case .ollama: return "Ollama (local)"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    var shortName: String {
        switch self {
        case .anthropic: return "Claude"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .openRouter: return "OpenRouter"
        case .lmStudio: return "LM Studio"
        case .ollama: return "Ollama"
        case .custom: return "Custom"
        }
    }

    var kind: ProviderKind { self == .anthropic ? .anthropic : .openAICompatible }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .lmStudio: return "http://localhost:1234/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .custom: return "http://localhost:8080/v1"
        }
    }

    var isLocal: Bool { self == .lmStudio || self == .ollama }
    var requiresKey: Bool { !(isLocal || self == .custom) }

    var symbol: String {
        switch self {
        case .anthropic: return "sparkle"
        case .openAI: return "circle.hexagongrid"
        case .gemini: return "star.leadinghalf.filled"
        case .openRouter: return "arrow.triangle.branch"
        case .lmStudio: return "desktopcomputer"
        case .ollama: return "cpu"
        case .custom: return "server.rack"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openAI: return "sk-…"
        case .gemini: return "AIza…"
        case .openRouter: return "sk-or-…"
        default: return "Optional"
        }
    }

    var keyURL: URL? {
        switch self {
        case .anthropic: return URL(string: "https://platform.claude.com/settings/keys")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .openRouter: return URL(string: "https://openrouter.ai/keys")
        default: return nil
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .anthropic: return ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
        default: return []
        }
    }

    var defaultModel: String { suggestedModels.first ?? "" }

    var helpText: String {
        switch self {
        case .anthropic: return "Uses the Claude Messages API with streaming, adaptive thinking and effort control."
        case .openAI: return "Chat Completions API. Effort maps to reasoning_effort."
        case .gemini: return "Gemini through Google's OpenAI-compatible endpoint."
        case .openRouter: return "One key for hundreds of models. Effort maps to OpenRouter's reasoning setting."
        case .lmStudio: return "Start LM Studio's local server (Developer tab → Start Server) and load a vision model."
        case .ollama: return "Run `ollama serve` and pull a vision model (e.g. llama3.2-vision, qwen2.5vl)."
        case .custom: return "Any server that speaks the OpenAI Chat Completions API (vLLM, llama.cpp, LocalAI, Groq…)."
        }
    }
}

struct ModelInfo: Codable, Hashable, Identifiable {
    var id: String
    var displayName: String?
    var maxOutputTokens: Int?
}

extension Array where Element == ModelInfo {
    /// A sensible default from a provider's list: skip embedding / audio models, prefer ones that can see images.
    var preferredForVision: ModelInfo? {
        let usable = filter { m in
            let id = m.id.lowercased()
            return !["embed", "whisper", "tts", "dall-e", "moderation", "rerank"].contains { id.contains($0) }
        }
        let visionHints = ["claude-opus", "vl", "vision", "llava", "gemma-3", "gemma3", "pixtral", "minicpm-v",
                           "moondream", "llama-4", "llama4", "gpt-4o", "gpt-5", "gemini", "qwen3", "mistral-small"]
        return usable.first { m in visionHints.contains { m.id.lowercased().contains($0) } } ?? usable.first
    }
}

struct ProviderConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var preset: ProviderPreset
    var baseURL: String
    var timeoutSeconds: Double = 300
    var cachedModels: [ModelInfo] = []

    var kind: ProviderKind { preset.kind }

    init(name: String, preset: ProviderPreset, baseURL: String? = nil) {
        self.name = name
        self.preset = preset
        self.baseURL = baseURL ?? preset.defaultBaseURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Provider"
        preset = try c.decodeIfPresent(ProviderPreset.self, forKey: .preset) ?? .custom
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? preset.defaultBaseURL
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 300
        cachedModels = try c.decodeIfPresent([ModelInfo].self, forKey: .cachedModels) ?? []
    }
}

// MARK: - Profiles

enum Effort: String, Codable, CaseIterable, Identifiable {
    case auto, minimal, low, medium, high, xhigh, max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Default"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        }
    }

    /// The closest level a provider understands (e.g. "max" → "high" for OpenAI, "minimal" → "low" for Claude).
    func clamped(to kind: ProviderKind) -> Effort {
        let allowed = Effort.supported(by: kind)
        if allowed.contains(self) { return self }
        switch (self, kind) {
        case (.minimal, .anthropic): return .low
        case (.xhigh, .openAICompatible), (.max, .openAICompatible): return .high
        default: return .auto
        }
    }

    static func supported(by kind: ProviderKind) -> [Effort] {
        switch kind {
        case .anthropic: return [.auto, .low, .medium, .high, .xhigh, .max]
        case .openAICompatible: return [.auto, .minimal, .low, .medium, .high]
        }
    }
}

enum MenuBarDisplay: String, Codable, CaseIterable, Identifiable {
    case letter, firstLine, iconOnly
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .letter: return "Answer letter (B)"
        case .firstLine: return "First line, shortened"
        case .iconOnly: return "Icon only (discreet)"
        }
    }
}

/// A profile pairs a prompt with a provider + model + reasoning settings.
struct Profile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var icon: String = "bolt.fill"
    var providerID: UUID?
    var model: String
    var effort: Effort = .auto
    /// nil = unlimited (the model's maximum).
    var maxTokens: Int? = 2048
    var showReasoning = false
    var systemPrompt: String
    var userPrompt: String
    var menuBarDisplay: MenuBarDisplay = .letter
    /// Optional global shortcut: "snap & ask with this profile".
    var hotkey: KeyCombo?

    init(name: String, icon: String, providerID: UUID?, model: String, effort: Effort = .auto,
         maxTokens: Int? = 2048, showReasoning: Bool = false, systemPrompt: String, userPrompt: String,
         menuBarDisplay: MenuBarDisplay = .letter) {
        self.name = name
        self.icon = icon
        self.providerID = providerID
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.showReasoning = showReasoning
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.menuBarDisplay = menuBarDisplay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "bolt.fill"
        providerID = try c.decodeIfPresent(UUID.self, forKey: .providerID)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        effort = try c.decodeIfPresent(Effort.self, forKey: .effort) ?? .auto
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        showReasoning = try c.decodeIfPresent(Bool.self, forKey: .showReasoning) ?? false
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        userPrompt = try c.decodeIfPresent(String.self, forKey: .userPrompt) ?? ""
        menuBarDisplay = try c.decodeIfPresent(MenuBarDisplay.self, forKey: .menuBarDisplay) ?? .letter
        hotkey = try c.decodeIfPresent(KeyCombo.self, forKey: .hotkey)
    }
}

// MARK: - Shortcuts

enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    case snapAndAsk, regionAndAsk, addScreen, addRegion, sendStack, clearStack, togglePanel, nextProfile, dismissAnswer, toggleDisguise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .snapAndAsk: return "Snap screen & ask"
        case .regionAndAsk: return "Select region & ask"
        case .addScreen: return "Add screen to stack"
        case .addRegion: return "Add region to stack"
        case .sendStack: return "Send stack"
        case .clearStack: return "Clear stack"
        case .togglePanel: return "Open / close panel"
        case .nextProfile: return "Switch to next profile"
        case .dismissAnswer: return "Hide answer overlay"
        case .toggleDisguise: return "Toggle disguise"
        }
    }

    var subtitle: String {
        switch self {
        case .snapAndAsk: return "Captures the screen under the cursor. Anything already in the stack is sent with it."
        case .regionAndAsk: return "Drag to select an area, then ask immediately."
        case .addScreen: return "Collect several screenshots (e.g. a question that scrolls) before asking."
        case .addRegion: return "Collect a selected area into the stack."
        case .sendStack: return "Sends every screenshot in the stack as one request."
        case .clearStack: return "Discards all collected screenshots."
        case .togglePanel: return "Shows the menu bar panel."
        case .nextProfile: return "Cycles through your profiles."
        case .dismissAnswer: return "Hides the floating answer overlay."
        case .toggleDisguise: return "Switches the menu bar icon between QuizSnapper and its disguise."
        }
    }

    var symbol: String {
        switch self {
        case .snapAndAsk: return "camera.viewfinder"
        case .regionAndAsk: return "crop"
        case .addScreen: return "plus.rectangle.on.rectangle"
        case .addRegion: return "plus.viewfinder"
        case .sendStack: return "paperplane.fill"
        case .clearStack: return "trash"
        case .togglePanel: return "menubar.rectangle"
        case .nextProfile: return "arrow.triangle.2.circlepath"
        case .dismissAnswer: return "eye.slash"
        case .toggleDisguise: return "theatermasks"
        }
    }

    var group: String {
        switch self {
        case .snapAndAsk, .regionAndAsk: return "Ask instantly"
        case .addScreen, .addRegion, .sendStack, .clearStack: return "Multi-screenshot stack"
        case .togglePanel, .nextProfile, .dismissAnswer, .toggleDisguise: return "App"
        }
    }
}

// MARK: - Settings

enum HUDPosition: String, Codable, CaseIterable, Identifiable {
    case topRight, topLeft, bottomRight, bottomLeft, topCenter, nearCursor
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .topRight: return "Top right"
        case .topLeft: return "Top left"
        case .bottomRight: return "Bottom right"
        case .bottomLeft: return "Bottom left"
        case .topCenter: return "Top center"
        case .nearCursor: return "Near the cursor"
        }
    }
}

enum ImageFormat: String, Codable, CaseIterable, Identifiable {
    case jpeg, png
    var id: String { rawValue }
}

struct AppSettings: Codable {
    var providers: [ProviderConfig] = []
    var profiles: [Profile] = []
    var activeProfileID: UUID?
    var shortcuts: [String: KeyCombo] = [:]

    // Answer presentation
    var hudEnabled = true
    var hudPosition: HUDPosition = .topRight
    var hudAutoHideSeconds: Double = 8
    var hudOpacity: Double = 1.0
    var hudShowExplanation = true
    var notifyOnAnswer = false
    var copyAnswerToClipboard = false
    /// Briefly show the answer letters in place of the menu bar icon when an answer arrives.
    /// 0 = off. Works disguised or not — the icon goes back to normal afterwards.
    var answerFlashSeconds: Double = 2
    /// Fill-in-the-blank answers (several text boxes) are copied to the clipboard as one
    /// pasteable string, joined with "; ", since they are too long to show in the menu bar.
    var autoCopyFillInAnswers = true
    var playSounds = true
    /// Master switch for every transient alert: the app's own floating status messages,
    /// system notifications and sounds. Off = QuizSnapper never interrupts you.
    var notificationsEnabled = true
    /// QuizSnapper's own floating bubbles ("Added to stack — 2 screenshots", "Profile: …",
    /// capture errors). Drawn by the app, so they appear whether or not macOS has granted
    /// notification permission — which is why they need their own switch.
    var showToasts = true

    // Capture
    var imageMaxDimension = 2048
    var imageFormat: ImageFormat = .jpeg
    var jpegQuality: Double = 0.85
    var maxStackSize = 12
    var snapIncludesStack = true

    // Disguise
    var disguise = DisguiseSettings()

    // Misc
    var historyLimit = 100
    var onboardingCompleted = false
    var onboardingStep = 0

    init() {}

    init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decodeIfPresent([ProviderConfig].self, forKey: .providers) ?? d.providers
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? d.profiles
        activeProfileID = try c.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        shortcuts = try c.decodeIfPresent([String: KeyCombo].self, forKey: .shortcuts) ?? d.shortcuts
        hudEnabled = try c.decodeIfPresent(Bool.self, forKey: .hudEnabled) ?? d.hudEnabled
        hudPosition = try c.decodeIfPresent(HUDPosition.self, forKey: .hudPosition) ?? d.hudPosition
        hudAutoHideSeconds = try c.decodeIfPresent(Double.self, forKey: .hudAutoHideSeconds) ?? d.hudAutoHideSeconds
        hudOpacity = try c.decodeIfPresent(Double.self, forKey: .hudOpacity) ?? d.hudOpacity
        hudShowExplanation = try c.decodeIfPresent(Bool.self, forKey: .hudShowExplanation) ?? d.hudShowExplanation
        notifyOnAnswer = try c.decodeIfPresent(Bool.self, forKey: .notifyOnAnswer) ?? d.notifyOnAnswer
        copyAnswerToClipboard = try c.decodeIfPresent(Bool.self, forKey: .copyAnswerToClipboard) ?? d.copyAnswerToClipboard
        answerFlashSeconds = try c.decodeIfPresent(Double.self, forKey: .answerFlashSeconds) ?? d.answerFlashSeconds
        autoCopyFillInAnswers = try c.decodeIfPresent(Bool.self, forKey: .autoCopyFillInAnswers) ?? d.autoCopyFillInAnswers
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        showToasts = try c.decodeIfPresent(Bool.self, forKey: .showToasts) ?? d.showToasts
        imageMaxDimension = try c.decodeIfPresent(Int.self, forKey: .imageMaxDimension) ?? d.imageMaxDimension
        imageFormat = try c.decodeIfPresent(ImageFormat.self, forKey: .imageFormat) ?? d.imageFormat
        jpegQuality = try c.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? d.jpegQuality
        maxStackSize = try c.decodeIfPresent(Int.self, forKey: .maxStackSize) ?? d.maxStackSize
        snapIncludesStack = try c.decodeIfPresent(Bool.self, forKey: .snapIncludesStack) ?? d.snapIncludesStack
        disguise = try c.decodeIfPresent(DisguiseSettings.self, forKey: .disguise) ?? d.disguise
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? d.historyLimit
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? d.onboardingCompleted
        onboardingStep = try c.decodeIfPresent(Int.self, forKey: .onboardingStep) ?? d.onboardingStep
    }

    func shortcut(_ action: ShortcutAction) -> KeyCombo? { shortcuts[action.rawValue] }

    func provider(id: UUID?) -> ProviderConfig? {
        guard let id else { return nil }
        return providers.first { $0.id == id }
    }

    var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
    }
}

// MARK: - History

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var profileName: String
    var providerName: String
    var model: String
    var imageCount: Int
    var answer: String
    var reasoning: String?
    var error: String?
    var durationSeconds: Double
    var inputTokens: Int?
    var outputTokens: Int?
}
