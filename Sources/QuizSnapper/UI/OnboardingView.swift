import SwiftUI

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, screenRecording, notifications, provider, shortcuts, done
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .screenRecording: return "Screen Recording"
        case .notifications: return "Notifications"
        case .provider: return "AI provider"
        case .shortcuts: return "Shortcuts"
        case .done: return "All set"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: return "hand.wave.fill"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .notifications: return "bell.badge.fill"
        case .provider: return "cpu.fill"
        case .shortcuts: return "command"
        case .done: return "checkmark.seal.fill"
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var permissions: PermissionsManager
    var finish: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var advanceScheduled = false
    @State private var hoveredStep: OnboardingStep?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    content
                        .padding(.horizontal, 40)
                        .padding(.top, 36)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                navigation
            }
        }
        .frame(width: 820, height: 560)
        .onAppear {
            step = OnboardingStep(rawValue: store.settings.onboardingStep) ?? .welcome
            permissions.startPolling()
        }
        .onDisappear { permissions.stopPolling() }
        .onChange(of: step) { _, new in store.settings.onboardingStep = new.rawValue }
        .onChange(of: permissions.screenRecording) { old, new in
            if step == .screenRecording && new == .granted && old != .granted { autoAdvance() }
        }
        .onChange(of: permissions.notifications) { old, new in
            if step == .notifications && new == .granted && old != .granted { autoAdvance() }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("QuizSnapper").font(.headline)
                    Text("Setup").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 18)

            ForEach(OnboardingStep.allCases) { s in
                Button {
                    step = s
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(stepColor(s).opacity(s == step ? 1 : 0.15))
                                .frame(width: 26, height: 26)
                            if isComplete(s) && s != step {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
                            } else {
                                Image(systemName: s.symbol).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(s == step ? .white : .secondary)
                            }
                        }
                        Text(s.title)
                            .font(.system(size: 13, weight: s == step ? .semibold : .regular))
                            .foregroundStyle(s == step ? .primary : .secondary)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(rowBackground(s)))
                    // Without this the transparent padding around the label ignores clicks.
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hoveredStep = s } else if hoveredStep == s { hoveredStep = nil }
                }
                .help("Go to “\(s.title)”")
            }
            Spacer()
            Text("Only Screen Recording is required.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 230)
        .background(VisualEffectBackground(material: .sidebar))
    }

    private func rowBackground(_ s: OnboardingStep) -> Color {
        if s == step { return Color.primary.opacity(0.06) }
        if s == hoveredStep { return Color.primary.opacity(0.035) }
        return .clear
    }

    private func stepColor(_ s: OnboardingStep) -> Color {
        if isComplete(s) && s != step { return .green }
        return .accentColor
    }

    private func isComplete(_ s: OnboardingStep) -> Bool {
        switch s {
        case .welcome: return step.rawValue > s.rawValue
        case .screenRecording: return permissions.screenRecording.isGranted
        case .notifications: return permissions.notifications.isGranted || step.rawValue > s.rawValue
        case .provider: return providerReady
        case .shortcuts: return step.rawValue > s.rawValue
        case .done: return false
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .screenRecording: permissionStep(.screenRecording)
        case .notifications: permissionStep(.notifications)
        case .provider: ProviderSetupStep(store: store)
        case .shortcuts: shortcutsStep
        case .done: doneStep
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("Welcome to QuizSnapper").font(.system(size: 28, weight: .bold))
            Text("Press a shortcut, and the question on your screen goes to the AI model of your choice. The answer appears in the menu bar and in a small floating overlay.")
                .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                feature("camera.viewfinder", "Full screen or a selected region", "Capture exactly what matters.")
                feature("square.stack.3d.up", "Multi-screenshot stack", "Collect several screenshots and ask about them in one go.")
                feature("text.bubble", "Profiles", "Pair any prompt with any model, effort level and token limit.")
                feature("desktopcomputer", "Cloud or local", "Claude, OpenAI, Gemini, OpenRouter — or LM Studio / Ollama on your Mac.")
            }
            .padding(.top, 6)
            Text("Setup takes about a minute.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, color: .accentColor, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func permissionStep(_ kind: PermissionKind) -> some View {
        let status = permissions.status(kind)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                IconTile(symbol: kind.symbol, color: status.isGranted ? .green : .accentColor, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title).font(.system(size: 26, weight: .bold))
                    StatusBadge(granted: status.isGranted, labelGranted: "Access granted",
                                labelMissing: kind.isRequired ? "Required" : "Optional")
                }
            }
            Text(kind.explanation).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if status.isGranted {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(.green)
                    Text("All good — continuing…").font(.headline)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.1)))
                .transition(.scale.combined(with: .opacity))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    instruction(1, kind == .screenRecording ? "Click “Grant access”. macOS opens System Settings → Privacy & Security → Screen & System Audio Recording."
                                                            : "Click “Allow notifications” and confirm the system prompt.")
                    if kind == .screenRecording {
                        instruction(2, "Turn on the switch next to QuizSnapper (use the + button if it isn't listed).")
                        instruction(3, "Come back here — this screen updates by itself.")
                    }
                    HStack {
                        Button {
                            permissions.request(kind)
                        } label: {
                            Label(kind == .screenRecording ? "Grant access" : "Allow notifications", systemImage: "lock.open.fill")
                                .padding(.horizontal, 8).padding(.vertical, 2)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        if kind == .screenRecording {
                            Button("Open System Settings") { permissions.openSettings(for: kind) }
                                .controlSize(.large)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))

                if kind == .screenRecording && permissions.shouldOfferRelaunch {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "arrow.clockwise.circle.fill").font(.title2).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Already turned it on?").font(.headline)
                            Text("macOS sometimes applies Screen Recording only after the app restarts. QuizSnapper will reopen right at this step.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("Restart QuizSnapper") { PermissionsManager.relaunch() }
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.1)))
                }
            }
        }
        .animation(.spring(duration: 0.35), value: status)
    }

    private func instruction(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your shortcuts").font(.system(size: 26, weight: .bold))
            Text("They work in every app. You can change any of them now or later in Settings → Shortcuts.")
                .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach([ShortcutAction.snapAndAsk, .regionAndAsk, .addScreen, .addRegion, .sendStack], id: \.self) { action in
                    HStack(spacing: 12) {
                        Image(systemName: action.symbol).frame(width: 22).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(action.title).font(.system(size: 13, weight: .medium))
                            Text(action.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        ShortcutRecorder(
                            combo: Binding(get: { store.settings.shortcut(action) },
                                           set: { store.settings.shortcuts[action.rawValue] = $0 }),
                            isRefused: model.refusedShortcuts.contains(action.rawValue),
                            conflictsWith: { ShortcutConflicts.find($0, in: store.settings, excluding: action.rawValue) })
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                    Divider().padding(.leading, 46)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))

            Toggle("Launch QuizSnapper at login", isOn: Binding(
                get: { permissions.launchAtLogin }, set: { permissions.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 60)).foregroundStyle(.green)
            Text("You're all set").font(.system(size: 28, weight: .bold))
            Text("QuizSnapper lives in the menu bar. Try it now:")
                .font(.title3).foregroundStyle(.secondary)
            if let combo = store.settings.shortcut(.snapAndAsk) {
                HStack(spacing: 10) {
                    KeyCapsView(combo: combo)
                    Text("snaps the screen and asks your active profile")
                }
            }
            if let combo = store.settings.shortcut(.addScreen), let send = store.settings.shortcut(.sendStack) {
                HStack(spacing: 10) {
                    KeyCapsView(combo: combo)
                    Text("collects screenshots, then")
                    KeyCapsView(combo: send)
                    Text("sends them together")
                }
            }
            if !permissions.screenRecording.isGranted {
                Label("Screen Recording is still off — screenshots won't work until you allow it.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if !providerReady {
                Label("No API key / model configured yet — add one in Settings → AI Providers.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Navigation

    private var navigation: some View {
        HStack {
            if step != .welcome {
                Button("Back") { go(-1) }
            }
            Spacer()
            if step == .screenRecording && !permissions.screenRecording.isGranted {
                Button("Skip for now") { go(1) }.buttonStyle(.link)
            }
            if step == .notifications && !permissions.notifications.isGranted {
                Button("Skip") { go(1) }.buttonStyle(.link)
            }
            Button(step == .done ? "Start using QuizSnapper" : "Continue") {
                if step == .done { complete() } else { go(1) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(step == .screenRecording && !permissions.screenRecording.isGranted)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func go(_ delta: Int) {
        if let next = OnboardingStep(rawValue: step.rawValue + delta) {
            step = next
        }
    }

    private func autoAdvance() {
        guard !advanceScheduled else { return }
        advanceScheduled = true
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            advanceScheduled = false
            if step == .screenRecording || step == .notifications { go(1) }
        }
    }

    private func complete() {
        store.settings.onboardingCompleted = true
        store.settings.onboardingStep = 0
        finish()
    }

    private var providerReady: Bool {
        guard let profile = store.activeProfile, let provider = store.provider(for: profile) else { return false }
        if profile.model.isEmpty { return false }
        if provider.preset.requiresKey { return !(Keychain.apiKey(for: provider) ?? "").isEmpty }
        return true
    }
}

// MARK: - Provider step

struct ProviderSetupStep: View {
    @ObservedObject var store: SettingsStore
    @State private var selectedProviderID: UUID?
    @State private var apiKey = ""
    @State private var testing = false
    @State private var result: String?
    @State private var ok = false

    private var provider: ProviderConfig? { store.settings.provider(id: selectedProviderID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect an AI model").font(.system(size: 26, weight: .bold))
            Text("Use a cloud model with an API key, or a model running locally on your Mac. You can add more providers and switch any time.")
                .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                ForEach(store.settings.providers.prefix(3)) { p in
                    Button {
                        select(p.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            IconTile(symbol: p.preset.symbol, color: .purple, size: 32)
                            Text(p.name).font(.headline)
                            Text(p.preset.isLocal ? "Free · runs on your Mac" : "Cloud · API key")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selectedProviderID == p.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(selectedProviderID == p.id ? Color.accentColor : .clear, lineWidth: 2)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if let provider {
                VStack(alignment: .leading, spacing: 10) {
                    Text(provider.preset.helpText).font(.callout).foregroundStyle(.secondary)
                    if provider.preset.isLocal {
                        TextField("Server URL", text: Binding(
                            get: { provider.baseURL },
                            set: { new in
                                if let i = store.settings.providers.firstIndex(where: { $0.id == provider.id }) {
                                    store.settings.providers[i].baseURL = new
                                }
                            }))
                            .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    } else {
                        HStack {
                            SecureField("API key (\(provider.preset.keyPlaceholder))", text: $apiKey)
                                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                                .onChange(of: apiKey) { _, new in Keychain.setAPIKey(new, for: provider) }
                            if let url = provider.preset.keyURL { Link("Get a key", destination: url) }
                        }
                    }
                    HStack {
                        Button {
                            Task { await test(provider) }
                        } label: {
                            Label("Test connection", systemImage: "bolt.horizontal.circle")
                        }
                        .disabled(testing)
                        if testing { ProgressView().controlSize(.small) }
                        if let result {
                            Label(result, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(ok ? .green : .red)
                                .lineLimit(3)
                                .font(.callout)
                        }
                    }
                    if let profile = store.activeProfile, profile.providerID == provider.id {
                        modelPicker(profile: profile, provider: provider)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            }
        }
        .onAppear {
            select(store.activeProfile?.providerID ?? store.settings.providers.first?.id)
        }
    }

    private func modelPicker(profile: Profile, provider: ProviderConfig) -> some View {
        let options = Array(Set(provider.cachedModels.map(\.id) + provider.preset.suggestedModels + [profile.model]))
            .filter { !$0.isEmpty }.sorted()
        return Picker("Model", selection: Binding(
            get: { profile.model },
            set: { new in
                if let idx = store.settings.profiles.firstIndex(where: { $0.id == profile.id }) {
                    store.settings.profiles[idx].model = new
                }
            })) {
            if profile.model.isEmpty { Text("Choose a model…").tag("") }
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
    }

    private func select(_ id: UUID?) {
        selectedProviderID = id
        result = nil
        guard let provider else { return }
        apiKey = Keychain.apiKey(for: provider) ?? ""
        // Make the first profile that uses this provider active.
        if let profile = store.settings.profiles.first(where: { $0.providerID == provider.id }) {
            store.setActiveProfile(profile.id)
        }
    }

    private func test(_ provider: ProviderConfig) async {
        testing = true
        defer { testing = false }
        do {
            let models = try await LLMClientFactory.make(for: provider, apiKey: Keychain.apiKey(for: provider)).listModels()
            store.setCachedModels(models, forProvider: provider.id)
            if let pick = models.preferredForVision { store.setModelIfEmpty(pick.id, forProfile: store.settings.activeProfileID) }
            ok = true
            result = models.isEmpty ? "Connected (no models loaded yet)" : "Connected · \(models.count) models"
        } catch {
            ok = false
            result = error.localizedDescription
        }
    }
}
