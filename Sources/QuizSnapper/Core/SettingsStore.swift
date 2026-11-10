import Combine
import Foundation

/// Single source of truth for user configuration. Persists to
/// ~/Library/Application Support/QuizSnapper/settings.json (API keys go to the Keychain).
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings
    @Published private(set) var history: [HistoryEntry] = []

    private var saveCancellable: AnyCancellable?
    /// Serial, so an older snapshot can never be written after a newer one.
    private let historyQueue = DispatchQueue(label: "quizsnapper.history")

    init() {
        if let data = try? Data(contentsOf: AppPaths.settingsFile) {
            do {
                settings = try JSONDecoder().decode(AppSettings.self, from: data)
            } catch {
                // Keep the broken file so nothing is lost, then start fresh.
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let backup = AppPaths.supportDir.appendingPathComponent("settings.corrupt-\(stamp).json")
                try? FileManager.default.copyItem(at: AppPaths.settingsFile, to: backup)
                Log.write("settings.json unreadable (\(error.localizedDescription)) — backed up to \(backup.lastPathComponent)")
                settings = Defaults.makeInitialSettings()
            }
        } else {
            settings = Defaults.makeInitialSettings()
        }
        if let data = try? Data(contentsOf: AppPaths.historyFile),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = decoded
        }
        normalize()
        saveCancellable = $settings
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.saveNow() }
        saveNow()
    }

    /// Earlier versions of `Defaults.quizSystemPrompt`. A profile still carrying one verbatim
    /// was never edited by the user, so it is upgraded in place — that is how prompt fixes
    /// (like the `FILL:` format for fill-in-the-blank answers) reach existing installs.
    private static let legacyQuizSystemPrompts: Set<String> = [
        """
        You answer multiple-choice quiz and exam questions from screenshots.
        The screenshots may show one question split across several images (for example a page that was scrolled). Treat all images as a single context, in the order given.

        Identify the question and every answer option, think it through carefully, then reply in exactly this format:
        Line 1: only the letter(s) of the correct answer(s), comma-separated — e.g. `B` or `A, C`.
        Line 2: a very short justification (under 20 words), in the same language as the question.

        If the options are not labeled with letters, label them A, B, C… in the order shown and say so.
        If there are several questions, answer each on its own line as `1: B`, `2: A, D`.
        If no question is visible, reply exactly `No quiz found`.
        """,
    ]

    /// Keeps references consistent (active profile exists, every action has an entry).
    private func normalize() {
        if settings.profiles.isEmpty {
            settings.profiles = Defaults.makeInitialSettings().profiles
        }
        for i in settings.profiles.indices
        where Self.legacyQuizSystemPrompts.contains(settings.profiles[i].systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)) {
            settings.profiles[i].systemPrompt = Defaults.quizSystemPrompt
            Log.write("Profile “\(settings.profiles[i].name)”: quiz prompt updated to the current default.")
        }
        if settings.activeProfileID == nil || !settings.profiles.contains(where: { $0.id == settings.activeProfileID }) {
            settings.activeProfileID = settings.profiles.first?.id
        }
    }

    func saveNow() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(settings)
            try data.write(to: AppPaths.settingsFile, options: .atomic)
        } catch {
            Log.write("Saving settings failed: \(error.localizedDescription)")
        }
    }

    // MARK: Convenience

    var activeProfile: Profile? { settings.activeProfile }

    func provider(for profile: Profile) -> ProviderConfig? { settings.provider(id: profile.providerID) }

    func setActiveProfile(_ id: UUID) { settings.activeProfileID = id }

    func cycleProfile() {
        guard let current = settings.activeProfileID,
              let idx = settings.profiles.firstIndex(where: { $0.id == current }),
              !settings.profiles.isEmpty else { return }
        settings.activeProfileID = settings.profiles[(idx + 1) % settings.profiles.count].id
    }

    func updateProvider(_ provider: ProviderConfig) {
        if let idx = settings.providers.firstIndex(where: { $0.id == provider.id }) {
            settings.providers[idx] = provider
        }
    }

    /// Safe after an `await`: looks the provider up by id, touches only its model list.
    func setCachedModels(_ models: [ModelInfo], forProvider id: UUID) {
        guard let idx = settings.providers.firstIndex(where: { $0.id == id }) else { return }
        settings.providers[idx].cachedModels = models
    }

    /// Fills in a model for a profile that has none yet (looked up by id).
    func setModelIfEmpty(_ model: String, forProfile id: UUID?) {
        guard let id, let idx = settings.profiles.firstIndex(where: { $0.id == id }),
              settings.profiles[idx].model.isEmpty else { return }
        settings.profiles[idx].model = model
    }

    func resetShortcutsToDefaults() {
        settings.shortcuts = [:]
        for (action, combo) in KeyCombo.defaults { settings.shortcuts[action.rawValue] = combo }
    }

    // MARK: History

    func addHistory(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > settings.historyLimit { history.removeLast(history.count - settings.historyLimit) }
        saveHistory()
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    private func saveHistory() {
        let snapshot = history
        historyQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: AppPaths.historyFile, options: .atomic)
            }
        }
    }
}
