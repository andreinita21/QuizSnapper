import AppKit
import Combine
import UserNotifications

struct RunState: Identifiable {
    enum Phase: Equatable {
        case preparing, waiting, streaming, done, failed(String), cancelled
    }

    let id = UUID()
    var profileName: String
    var profileIcon: String
    var providerName: String
    var model: String
    var menuBarDisplay: MenuBarDisplay
    var imageCount: Int
    var phase: Phase = .preparing
    var answer = ""
    var reasoning = ""
    var startedAt = Date()
    var finishedAt: Date?
    var inputTokens: Int?
    var outputTokens: Int?
    var stopReason: String?

    var isActive: Bool {
        switch phase {
        case .preparing, .waiting, .streaming: return true
        default: return false
        }
    }

    var letters: String? { AnswerParser.letters(from: answer) }
    /// Letters to click vs. values to type — decides what the menu bar flashes and what gets copied.
    var shape: AnswerShape { AnswerParser.shape(of: answer) }
    /// True when the first line of the reply is the answer itself (letters or fill-in values),
    /// so the UI can show it on its own and keep only the justification as body text.
    var hasHeadline: Bool { shape != .none }
    var explanation: String { AnswerParser.explanation(of: answer) }

    var duration: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }

    var errorMessage: String? {
        if case .failed(let msg) = phase { return msg }
        return nil
    }

    var wasTruncated: Bool { stopReason == "max_tokens" }
}

/// Central controller: capture stack, running requests, hotkeys.
@MainActor
final class AppModel: ObservableObject {
    static var shared: AppModel!

    let store: SettingsStore
    let permissions: PermissionsManager

    @Published private(set) var stack: [CapturedShot] = []
    @Published private(set) var run: RunState?
    @Published private(set) var isCapturing = false
    @Published private(set) var refusedShortcuts: Set<String> = []
    @Published var toast: String?

    /// Screenshots of the last request, kept for "retry / ask again with another profile".
    private(set) var lastShots: [CapturedShot] = []
    private var runTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var recordingCount = 0
    private var isRecordingShortcut: Bool { recordingCount > 0 }
    private var toastTask: Task<Void, Never>?

    // UI hooks wired by the AppDelegate
    var onBeforeCapture: (() -> Void)?
    var onRunStarted: (() -> Void)?
    var onRunFinished: (() -> Void)?
    var onTogglePanel: (() -> Void)?
    var onDismissAnswer: (() -> Void)?
    var onNeedsPermissions: (() -> Void)?

    init(store: SettingsStore, permissions: PermissionsManager) {
        self.store = store
        self.permissions = permissions
        AppModel.shared = self

        store.$settings
            .map { s -> String in
                let base = s.shortcuts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.keyCode)/\($0.value.modifiers)" }
                let prof = s.profiles.compactMap { p in p.hotkey.map { "\(p.id)=\($0.keyCode)/\($0.modifiers)" } }
                return (base + prof).joined(separator: ";")
            }
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.registerHotkeys() }
            }
            .store(in: &cancellables)

        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    var settings: AppSettings { store.settings }
    var activeProfile: Profile? { store.activeProfile }

    // MARK: - Hotkeys

    func registerHotkeys() {
        guard !isRecordingShortcut else { return }
        HotKeyCenter.shared.unregisterAll()
        var refused = Set<String>()
        for action in ShortcutAction.allCases {
            guard let combo = settings.shortcut(action) else { continue }
            if !HotKeyCenter.shared.register(combo, handler: { [weak self] in self?.perform(action) }) {
                refused.insert(action.rawValue)
            }
        }
        for profile in settings.profiles {
            guard let combo = profile.hotkey else { continue }
            let id = profile.id
            if !HotKeyCenter.shared.register(combo, handler: { [weak self] in self?.snapAndAsk(profileID: id) }) {
                refused.insert(profile.id.uuidString)
            }
        }
        refusedShortcuts = refused
    }

    func beginShortcutRecording() {
        recordingCount += 1
        HotKeyCenter.shared.unregisterAll()
    }

    func endShortcutRecording() {
        recordingCount = max(0, recordingCount - 1)
        guard recordingCount == 0 else { return }
        registerHotkeys()
    }

    // MARK: - Actions

    func perform(_ action: ShortcutAction) {
        Log.write("Action: \(action.rawValue)")
        switch action {
        case .snapAndAsk: snapAndAsk()
        case .regionAndAsk: regionAndAsk()
        case .addScreen: addToStack(region: false)
        case .addRegion: addToStack(region: true)
        case .sendStack: sendStack()
        case .clearStack: clearStack()
        case .togglePanel: onTogglePanel?()
        case .nextProfile:
            store.cycleProfile()
            if let p = activeProfile { showToast("Profile: \(p.name)") }
        case .dismissAnswer: onDismissAnswer?()
        case .toggleDisguise: store.settings.disguise.enabled.toggle()
        }
    }

    func snapAndAsk(profileID: UUID? = nil) {
        Task {
            guard let shot = await capture(region: false) else { return }
            let include = settings.snapIncludesStack
            let shots = (include ? stack : []) + [shot]
            if include { stack.removeAll() }
            ask(with: shots, profileID: profileID)
        }
    }

    func regionAndAsk(profileID: UUID? = nil) {
        Task {
            guard let shot = await capture(region: true) else { return }
            let include = settings.snapIncludesStack
            let shots = (include ? stack : []) + [shot]
            if include { stack.removeAll() }
            ask(with: shots, profileID: profileID)
        }
    }

    func addToStack(region: Bool) {
        guard stack.count < settings.maxStackSize else {
            showToast("Stack is full (\(settings.maxStackSize)). Send or clear it.")
            sound("Funk")
            return
        }
        Task {
            guard let shot = await capture(region: region) else { return }
            stack.append(shot)
            showToast("Added to stack — \(stack.count) screenshot\(stack.count == 1 ? "" : "s")")
        }
    }

    func sendStack(profileID: UUID? = nil) {
        guard !stack.isEmpty else {
            showToast("Stack is empty — add screenshots first")
            return
        }
        let shots = stack
        stack.removeAll()
        ask(with: shots, profileID: profileID)
    }

    func clearStack() {
        guard !stack.isEmpty else { return }
        stack.removeAll()
        showToast("Stack cleared")
    }

    func removeShot(_ id: UUID) { stack.removeAll { $0.id == id } }

    func moveShot(_ id: UUID, by offset: Int) {
        guard let idx = stack.firstIndex(where: { $0.id == id }) else { return }
        let target = idx + offset
        guard stack.indices.contains(target) else { return }
        stack.swapAt(idx, target)
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        flushPending()
        if run?.isActive == true {
            run?.phase = .cancelled
            run?.finishedAt = Date()
            onRunFinished?()
        }
    }

    func retry(profileID: UUID? = nil) {
        guard !lastShots.isEmpty else { return }
        ask(with: lastShots, profileID: profileID)
    }

    // MARK: - Capture

    private func capture(region: Bool) async -> CapturedShot? {
        guard !isCapturing else { return nil }
        if !permissions.screenRecording.isGranted && !CGPreflightScreenCaptureAccess() {
            permissions.refresh()
            onNeedsPermissions?()
            return nil
        }
        isCapturing = true
        defer { isCapturing = false }
        onBeforeCapture?()
        // Let the popover/HUD fade out before the frame is grabbed.
        try? await Task.sleep(nanoseconds: 120_000_000)
        do {
            if region {
                guard let image = try await RegionSelector.select() else { return nil }
                sound("Tink")
                return CapturedShot(image: image, isRegion: true)
            } else {
                let image = try await ScreenCapturer.captureScreen()
                sound("Tink")
                return CapturedShot(image: image, isRegion: false)
            }
        } catch {
            Log.write("Capture failed: \(error.localizedDescription)")
            if case CaptureError.permissionDenied = error {
                permissions.refresh()
                onNeedsPermissions?()
            } else {
                showToast(error.localizedDescription)
            }
            sound("Basso")
            return nil
        }
    }

    // MARK: - Asking

    private func ask(with shots: [CapturedShot], profileID: UUID?) {
        runTask?.cancel()
        // Drop tokens still buffered from the request being replaced.
        pendingText = ""
        pendingReasoning = ""
        let profile = settings.profiles.first { $0.id == profileID } ?? activeProfile
        guard let profile else { return }
        lastShots = shots

        let provider = store.provider(for: profile)
        var state = RunState(profileName: profile.name, profileIcon: profile.icon,
                             providerName: provider?.name ?? "—", model: profile.model,
                             menuBarDisplay: profile.menuBarDisplay, imageCount: shots.count)
        guard let provider else {
            state.phase = .failed(LLMError.noProvider.localizedDescription)
            run = state
            onRunStarted?()
            return
        }
        run = state
        onRunStarted?()

        let settings = self.settings
        let apiKey = Keychain.apiKey(for: provider)
        let images = shots.map(\.image)
        Log.write("Asking \(provider.name)/\(profile.model) with \(shots.count) image(s), profile \(profile.name)")

        runTask = Task { [weak self] in
            let encoded = await Task.detached(priority: .userInitiated) {
                ImageEncoder.encodeAll(images, settings: settings)
            }.value
            guard let self, !Task.isCancelled else { return }
            if encoded.isEmpty {
                self.finish(error: LLMError.api("Couldn't encode the screenshot(s)."))
                return
            }
            if encoded.count < images.count {
                Log.write("Warning: \(images.count - encoded.count) image(s) could not be encoded and were skipped")
            }

            let request = LLMRequest(model: profile.model, systemPrompt: profile.systemPrompt,
                                     userPrompt: profile.userPrompt, images: encoded, effort: profile.effort,
                                     maxTokens: profile.maxTokens, showReasoning: profile.showReasoning)
            let client = LLMClientFactory.make(for: provider, apiKey: apiKey)
            self.run?.phase = .waiting
            do {
                for try await event in client.stream(request) {
                    if Task.isCancelled { break }
                    self.apply(event)
                }
                if Task.isCancelled { return }
                self.finish(error: nil)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                self.finish(error: error)
            }
        }
    }

    private var pendingText = ""
    private var pendingReasoning = ""
    private var flushScheduled = false

    private func flushPending() {
        flushScheduled = false
        guard run != nil, !(pendingText.isEmpty && pendingReasoning.isEmpty) else { return }
        if !pendingText.isEmpty {
            run?.answer += pendingText
            if run?.phase == .waiting { run?.phase = .streaming }
        }
        if !pendingReasoning.isEmpty { run?.reasoning += pendingReasoning }
        pendingText = ""
        pendingReasoning = ""
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.flushPending() }
    }

    private func apply(_ event: StreamEvent) {
        guard run != nil else { return }
        switch event {
        case .text(let t):
            pendingText += t
            // First token: show it right away so the answer feels instant.
            if run?.answer.isEmpty == true && run?.phase == .waiting { flushPending() } else { scheduleFlush() }
        case .reasoning(let r):
            pendingReasoning += r
            scheduleFlush()
        case .usage(let input, let output):
            if let input { run?.inputTokens = input }
            if let output { run?.outputTokens = output }
        case .finished(let reason):
            run?.stopReason = reason
        }
    }

    private func finish(error: Error?) {
        flushPending()
        guard var state = run else { return }
        state.finishedAt = Date()
        if let error {
            state.phase = .failed(error.localizedDescription)
            state.answer = state.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.write("Request failed: \(error.localizedDescription)")
            sound("Basso")
        } else {
            state.phase = .done
            state.answer = state.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if state.answer.isEmpty { state.answer = "(empty response)" }
            Log.write("Answer (\(String(format: "%.1f", state.duration))s): \(state.answer.prefix(200))")
            sound("Glass")
            // A fill-in answer is a list of values for text boxes: put the pasteable
            // "a; b; c" form on the clipboard, since it can't fit in the menu bar.
            if settings.autoCopyFillInAnswers, let fill = state.shape.clipboardText {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fill, forType: .string)
                Log.write("Fill-in answer copied to clipboard: \(fill)")
            } else if settings.copyAnswerToClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(state.answer, forType: .string)
            }
            if settings.notificationsEnabled && settings.notifyOnAnswer { postNotification(for: state) }
        }
        run = state
        store.addHistory(HistoryEntry(profileName: state.profileName, providerName: state.providerName,
                                      model: state.model, imageCount: state.imageCount, answer: state.answer,
                                      reasoning: state.reasoning.isEmpty ? nil : state.reasoning,
                                      error: state.errorMessage, durationSeconds: state.duration,
                                      inputTokens: state.inputTokens, outputTokens: state.outputTokens))
        onRunFinished?()
    }

    /// Used only by the `-snapshotUI` debug renderer.
    func debugSetState(run: RunState?, stack: [CapturedShot]) {
        self.run = run
        self.stack = stack
    }

    // MARK: - Feedback

    func showToast(_ message: String) {
        // Gated here rather than at each call site so nothing can leak a bubble through.
        // Returning early also keeps `toast` nil, which stops the overlay being forced
        // open by the `model.toast != nil` check in the AppDelegate.
        guard settings.notificationsEnabled, settings.showToasts else { return }
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
        onRunStarted?() // make sure the overlay is visible to show the toast
    }

    private func sound(_ name: String) {
        guard settings.notificationsEnabled, settings.playSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    private func postNotification(for state: RunState) {
        let content = UNMutableNotificationContent()
        content.title = state.letters.map { "Answer: \($0)" } ?? state.profileName
        content.body = String(state.explanation.isEmpty ? state.answer.prefix(240) : state.explanation.prefix(240))
        let request = UNNotificationRequest(identifier: state.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
