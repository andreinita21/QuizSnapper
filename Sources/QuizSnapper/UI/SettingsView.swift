import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, profiles, providers, shortcuts, disguise, permissions, history, about
    /// Must be `Self`, not `rawValue`: `List` selection matches rows by `Element.ID`, so a
    /// `String` id would never match the `SettingsPane` selection binding below.
    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .profiles: return "Profiles & Prompts"
        case .providers: return "AI Providers"
        case .shortcuts: return "Shortcuts"
        case .disguise: return "Disguise"
        case .permissions: return "Permissions"
        case .history: return "History"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .profiles: return "text.bubble.fill"
        case .providers: return "cpu.fill"
        case .shortcuts: return "command"
        case .disguise: return "theatermasks.fill"
        case .permissions: return "lock.shield.fill"
        case .history: return "clock.fill"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: return .gray
        case .profiles: return .blue
        case .providers: return .purple
        case .shortcuts: return .pink
        case .disguise: return .indigo
        case .permissions: return .green
        case .history: return .orange
        case .about: return .teal
        }
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var pane: SettingsPane = .general
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var permissions: PermissionsManager
    let disguise: DisguiseEngine
    @ObservedObject var nav: SettingsNavigation
    var runOnboarding: () -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { nav.pane }, set: { if let p = $0 { nav.pane = p } })) {
                ForEach(SettingsPane.allCases) { pane in
                    Label {
                        Text(pane.title)
                    } icon: {
                        IconTile(symbol: pane.symbol, color: pane.color, size: 22)
                    }
                    .tag(pane)
                    .badge(pane == .permissions && !permissions.allRequiredGranted ? Text("!") : nil)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
        } detail: {
            Group {
                switch nav.pane {
                case .general: GeneralPane(store: store, permissions: permissions)
                case .profiles: ProfilesPane(model: model, store: store)
                case .providers: ProvidersPane(store: store)
                case .shortcuts: ShortcutsPane(model: model, store: store)
                case .disguise: DisguisePane(store: store, engine: disguise)
                case .permissions: PermissionsPane(permissions: permissions, runOnboarding: runOnboarding)
                case .history: HistoryPane(store: store)
                case .about: AboutPane()
                }
            }
            .navigationTitle(nav.pane.title)
        }
        .frame(minWidth: 860, minHeight: 600)
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var permissions: PermissionsManager

    private let dimensions = [1024, 1568, 2048, 2560, 3072, 4096]

    var body: some View {
        Form {
            Section {
                Toggle("Show floating answer overlay", isOn: $store.settings.hudEnabled)
                Picker("Position", selection: $store.settings.hudPosition) {
                    ForEach(HUDPosition.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(!store.settings.hudEnabled)
                Toggle("Show explanation in overlay", isOn: $store.settings.hudShowExplanation)
                    .disabled(!store.settings.hudEnabled)
                LabeledContent("Hide after") {
                    HStack {
                        Slider(value: Binding(get: { store.settings.hudAutoHideSeconds },
                                              set: { store.settings.hudAutoHideSeconds = $0.rounded() }), in: 0...60)
                        Text(store.settings.hudAutoHideSeconds == 0 ? "Never" : "\(Int(store.settings.hudAutoHideSeconds))s")
                            .monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                .disabled(!store.settings.hudEnabled)
                LabeledContent("Opacity") {
                    HStack {
                        Slider(value: $store.settings.hudOpacity, in: 0.3...1)
                        Text("\(Int(store.settings.hudOpacity * 100))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                .disabled(!store.settings.hudEnabled)
            } header: {
                Text("Answer")
            } footer: {
                Text("The overlay and panel are hidden from screenshots and screen sharing.").foregroundStyle(.secondary)
            }

            Section {
                Toggle("Copy answer to clipboard automatically", isOn: $store.settings.copyAnswerToClipboard)
                Toggle(isOn: $store.settings.autoCopyFillInAnswers) {
                    Text("Fill‑in answers always go to the clipboard")
                    Text("For questions with text boxes instead of A/B/C options: the values in order, joined with “; ”. Multiple-choice answers still show in the menu bar.")
                }
                Toggle("Launch QuizSnapper at login", isOn: Binding(
                    get: { permissions.launchAtLogin },
                    set: { permissions.setLaunchAtLogin($0) }))
            } header: {
                Text("Behavior")
            }

            Section {
                Toggle(isOn: $store.settings.notificationsEnabled) {
                    Text("Notify me")
                    Text("One switch for all three below — off means QuizSnapper never interrupts you.")
                }
                Group {
                    Toggle(isOn: $store.settings.showToasts) {
                        Text("Floating status messages")
                        Text("“Added to stack — 2 screenshots”, “Profile: …”, capture errors.")
                    }
                    Toggle("System notification with the answer", isOn: $store.settings.notifyOnAnswer)
                    if store.settings.notifyOnAnswer && !permissions.notifications.isGranted {
                        HStack {
                            Text("macOS hasn't allowed notifications for QuizSnapper yet.").foregroundStyle(.orange)
                            Button("Allow") { permissions.requestNotifications() }
                        }
                        .font(.callout)
                    }
                    Toggle("Play sounds", isOn: $store.settings.playSounds)
                }
                .padding(.leading, 18)
                .disabled(!store.settings.notificationsEnabled)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Only “System notification with the answer” uses macOS notifications. Floating status messages and sounds come from QuizSnapper itself, so they show up even when you have never granted notification permission — turn them off here. The answer overlay has its own switch under Answer, above.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Image format", selection: $store.settings.imageFormat) {
                    Text("JPEG (smaller, faster)").tag(ImageFormat.jpeg)
                    Text("PNG (lossless)").tag(ImageFormat.png)
                }
                if store.settings.imageFormat == .jpeg {
                    LabeledContent("JPEG quality") {
                        HStack {
                            Slider(value: $store.settings.jpegQuality, in: 0.5...1)
                            Text("\(Int(store.settings.jpegQuality * 100))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                    }
                }
                Picker("Max image size (longest side)", selection: $store.settings.imageMaxDimension) {
                    ForEach(dimensions, id: \.self) { Text("\($0) px").tag($0) }
                }
                Stepper("Max screenshots in stack: \(store.settings.maxStackSize)",
                        value: $store.settings.maxStackSize, in: 2...50)
                Toggle("“Snap & ask” also sends what's in the stack", isOn: $store.settings.snapIncludesStack)
            } header: {
                Text("Capture")
            } footer: {
                Text("Bigger images read small text better but cost more tokens and time. 2048 px is a good default; local models are often faster at 1024–1568.")
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                Stepper("Keep last \(store.settings.historyLimit) answers", value: $store.settings.historyLimit, in: 10...1000, step: 10)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

struct ShortcutsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore

    private var groups: [String] { ["Ask instantly", "Multi-screenshot stack", "App"] }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.green).font(.title2)
                    Text("Shortcuts work in every app and don't need Accessibility or Input Monitoring permission. Click a shortcut to record a new one; press ⌫ to clear it or ⎋ to cancel.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(groups, id: \.self) { group in
                Section(group) {
                    ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                        row(action)
                    }
                }
            }
            Section {
                Text("Each profile can also have its own “snap & ask with this profile” shortcut — set it in Profiles & Prompts.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Reset all to defaults") { store.resetShortcutsToDefaults() }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ action: ShortcutAction) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: action.symbol, color: .pink, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                Text(action.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.refusedShortcuts.contains(action.rawValue) {
                    Label("macOS refused this shortcut — another app probably uses it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            ShortcutRecorder(
                combo: Binding(get: { store.settings.shortcut(action) },
                               set: { store.settings.shortcuts[action.rawValue] = $0 }),
                isRefused: model.refusedShortcuts.contains(action.rawValue),
                conflictsWith: { conflict(for: $0, excluding: action.rawValue) })
        }
        .padding(.vertical, 2)
    }

    func conflict(for combo: KeyCombo, excluding key: String) -> String? {
        ShortcutConflicts.find(combo, in: store.settings, excluding: key)
    }
}

enum ShortcutConflicts {
    static func find(_ combo: KeyCombo, in settings: AppSettings, excluding key: String) -> String? {
        for action in ShortcutAction.allCases where action.rawValue != key {
            if settings.shortcut(action) == combo { return action.title }
        }
        for profile in settings.profiles where profile.id.uuidString != key {
            if profile.hotkey == combo { return profile.name }
        }
        return nil
    }
}

// MARK: - Permissions

struct PermissionsPane: View {
    @ObservedObject var permissions: PermissionsManager
    var runOnboarding: () -> Void

    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases) { kind in
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(symbol: kind.symbol, color: permissions.status(kind).isGranted ? .green : .orange, size: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(kind.title).font(.headline)
                                Text(kind.isRequired ? "Required" : "Optional")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                            Text(kind.explanation).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            StatusBadge(granted: permissions.status(kind).isGranted)
                            if !permissions.status(kind).isGranted {
                                Button("Grant…") { permissions.request(kind) }
                            } else {
                                Button("Open Settings") { permissions.openSettings(for: kind) }.buttonStyle(.link)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("Global shortcuts use the system hotkey API, so Accessibility and Input Monitoring are not needed.")
                    .foregroundStyle(.secondary)
            }

            Section("Troubleshooting") {
                LabeledContent("Enabled it but still shows as missing?") {
                    Button("Restart QuizSnapper") { PermissionsManager.relaunch() }
                }
                LabeledContent("Walk through setup again") {
                    Button("Open setup assistant") { runOnboarding() }
                }
                Text("macOS remembers permissions per code signature. Build with ./build.sh — it signs every build with the same certificate, so you only grant access once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }
}

// MARK: - History

struct HistoryPane: View {
    @ObservedObject var store: SettingsStore
    @State private var selection: UUID?
    @State private var confirmClear = false

    private var countLabel: String {
        switch store.history.count {
        case 0: return "No answers yet"
        case 1: return "1 answer"
        case let n: return "\(n) answers"
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(store.history, selection: $selection) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(AnswerParser.letters(from: entry.answer) ?? AnswerParser.firstLine(of: entry.answer, limit: 30))
                                .font(.headline)
                                .foregroundStyle(entry.error != nil ? .red : .primary)
                            Spacer()
                            Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(entry.profileName) · \(entry.model)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(entry.id)
                }
                Divider()
                // Lives here rather than in a `.toolbar`: the settings window is a plain NSWindow
                // with no NSToolbar, so toolbar items never get anywhere to be drawn.
                HStack(spacing: 8) {
                    Text(countLabel).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History", systemImage: "trash") { confirmClear = true }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(store.history.isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(minWidth: 240, idealWidth: 260)

            Group {
                if let entry = store.history.first(where: { $0.id == selection }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(entry.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                                GridRow { Text("Profile").foregroundStyle(.secondary); Text(entry.profileName) }
                                GridRow { Text("Provider").foregroundStyle(.secondary); Text("\(entry.providerName) · \(entry.model)") }
                                GridRow { Text("Images").foregroundStyle(.secondary); Text("\(entry.imageCount)") }
                                GridRow { Text("Time").foregroundStyle(.secondary); Text(String(format: "%.1f s", entry.durationSeconds)) }
                                if let i = entry.inputTokens, let o = entry.outputTokens {
                                    GridRow { Text("Tokens").foregroundStyle(.secondary); Text("\(i.compactTokens) in · \(o.compactTokens) out") }
                                }
                            }
                            .font(.callout)
                            Divider()
                            if let error = entry.error {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                            } else {
                                Text(markdown(entry.answer)).textSelection(.enabled)
                            }
                            if let reasoning = entry.reasoning {
                                DisclosureGroup("Reasoning") {
                                    Text(reasoning).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            Button("Copy answer") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.answer, forType: .string)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.tertiary)
                        Text(store.history.isEmpty ? "No answers yet" : "Select an answer").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Delete all \(store.history.count) saved answers?",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                store.clearHistory()
                selection = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }
}

// MARK: - About

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("QuizSnapper").font(.largeTitle.weight(.bold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0")")
                .foregroundStyle(.secondary)
            Text("Snap a question, get the answer — with Claude, OpenAI, Gemini, OpenRouter or a local model.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
            HStack {
                Button("Show Logs") { NSWorkspace.shared.activateFileViewerSelecting([Log.logURL]) }
                Button("Show Settings File") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.settingsFile]) }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
