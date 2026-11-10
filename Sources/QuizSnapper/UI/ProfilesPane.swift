import SwiftUI

// MARK: - Profiles

struct ProfilesPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.settings.profiles) { profile in
                        HStack(spacing: 10) {
                            IconTile(symbol: profile.icon, color: .blue, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.name).lineLimit(1)
                                Text(subtitle(for: profile)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if profile.id == store.settings.activeProfileID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Active profile")
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(profile.id)
                    }
                    .onMove { store.settings.profiles.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack(spacing: 2) {
                    Button { addProfile() } label: { Image(systemName: "plus") }.help("New profile")
                    Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }
                        .help("Duplicate").disabled(selection == nil)
                    Button { delete() } label: { Image(systemName: "minus") }
                        .help("Delete").disabled(selection == nil || store.settings.profiles.count <= 1)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 230, idealWidth: 250, maxWidth: 300)

            Group {
                if let idx = store.settings.profiles.firstIndex(where: { $0.id == selection }) {
                    ProfileEditor(profile: $store.settings.profiles[idx], model: model, store: store)
                        .id(store.settings.profiles[idx].id)
                } else {
                    Text("Select a profile").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = store.settings.activeProfileID } }
    }

    private func subtitle(for profile: Profile) -> String {
        let provider = store.provider(for: profile)?.name ?? "No provider"
        return "\(provider) · \(profile.model.isEmpty ? "no model" : profile.model)"
    }

    private func addProfile() {
        let provider = store.settings.providers.first
        let p = Profile(name: "New profile", icon: "bolt.fill", providerID: provider?.id,
                        model: provider?.cachedModels.first?.id ?? provider?.preset.defaultModel ?? "",
                        systemPrompt: Defaults.quizSystemPrompt, userPrompt: Defaults.quizUserPrompt)
        store.settings.profiles.append(p)
        selection = p.id
    }

    private func duplicate() {
        guard let p = store.settings.profiles.first(where: { $0.id == selection }) else { return }
        var copy = p
        copy.id = UUID()
        copy.name = p.name + " copy"
        copy.hotkey = nil
        store.settings.profiles.append(copy)
        selection = copy.id
    }

    private func delete() {
        guard let id = selection, store.settings.profiles.count > 1 else { return }
        store.settings.profiles.removeAll { $0.id == id }
        if store.settings.activeProfileID == id { store.settings.activeProfileID = store.settings.profiles.first?.id }
        selection = store.settings.profiles.first?.id
    }
}

struct ProfileEditor: View {
    @Binding var profile: Profile
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @State private var fetching = false
    @State private var fetchError: String?
    @State private var maxTokensText = ""

    private let icons = ["checkmark.circle.fill", "bolt.fill", "graduationcap.fill", "brain.head.profile", "book.fill",
                         "function", "chevron.left.forwardslash.chevron.right", "globe", "flask.fill", "desktopcomputer",
                         "text.magnifyingglass", "sparkles", "star.fill", "doc.text.fill"]

    private var provider: ProviderConfig? { store.settings.provider(id: profile.providerID) }

    var body: some View {
        Form {
            Section {
                HStack {
                    Menu {
                        ForEach(icons, id: \.self) { icon in
                            Button { profile.icon = icon } label: { Image(systemName: icon) }
                        }
                    } label: {
                        IconTile(symbol: profile.icon, color: .blue, size: 30)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    TextField("Name", text: $profile.name).textFieldStyle(.roundedBorder).font(.title3)
                        .labelsHidden().multilineTextAlignment(.leading)
                    if profile.id == store.settings.activeProfileID {
                        StatusBadge(granted: true, labelGranted: "Active")
                    } else {
                        Button("Make active") { store.setActiveProfile(profile.id) }
                    }
                }
            }

            Section {
                Picker("Provider", selection: $profile.providerID) {
                    ForEach(store.settings.providers) { p in
                        Label(p.name, systemImage: p.preset.symbol).tag(Optional(p.id))
                    }
                }
                .onChange(of: profile.providerID) { _, _ in
                    if let provider, !Effort.supported(by: provider.kind).contains(profile.effort) { profile.effort = .auto }
                }

                LabeledContent("Model") {
                    HStack(spacing: 6) {
                        TextField("model id", text: $profile.model, prompt: Text("model id")).textFieldStyle(.roundedBorder)
                            .labelsHidden().multilineTextAlignment(.leading)
                            .font(.system(.body, design: .monospaced))
                        Menu {
                            let models = modelChoices
                            if models.isEmpty { Text("No models loaded — click Refresh") }
                            ForEach(models, id: \.self) { m in Button(m) { profile.model = m } }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        Button {
                            Task { await fetchModels() }
                        } label: {
                            if fetching { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                        }
                        .buttonStyle(.borderless)
                        .help("Load the model list from the provider")
                    }
                }
                if let fetchError {
                    Text(fetchError).font(.caption).foregroundStyle(.red)
                }

                Picker("Reasoning effort", selection: Binding(
                    get: { profile.effort.clamped(to: provider?.kind ?? .anthropic) },
                    set: { profile.effort = $0 })) {
                    ForEach(Effort.supported(by: provider?.kind ?? .anthropic)) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent("Max output tokens") {
                    HStack {
                        Toggle("Unlimited", isOn: Binding(
                            get: { profile.maxTokens == nil },
                            set: { profile.maxTokens = $0 ? nil : (Int(maxTokensText) ?? 4096) }))
                            .toggleStyle(.checkbox)
                        TextField("Tokens", text: $maxTokensText, prompt: Text("4096"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .disabled(profile.maxTokens == nil)
                            .onChange(of: maxTokensText) { _, new in
                                if profile.maxTokens != nil, let v = Int(new.filter(\.isNumber)), v > 0 { profile.maxTokens = v }
                            }
                    }
                }
                Toggle("Show the model's reasoning", isOn: $profile.showReasoning)
            } header: {
                Text("Model")
            } footer: {
                Text(effortHelp).foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("System prompt").font(.headline)
                        Spacer()
                        Menu("Templates") {
                            Button("Quiz — letter + short reason") {
                                profile.systemPrompt = Defaults.quizSystemPrompt; profile.userPrompt = Defaults.quizUserPrompt
                            }
                            Button("Explain step by step") {
                                profile.systemPrompt = Defaults.explainSystemPrompt; profile.userPrompt = Defaults.explainUserPrompt
                            }
                            Button("Open question / code") {
                                profile.systemPrompt = Defaults.openSystemPrompt; profile.userPrompt = Defaults.openUserPrompt
                            }
                        }
                        .fixedSize()
                    }
                    TextEditor(text: $profile.systemPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 170)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Message sent with the screenshots").font(.headline)
                    TextEditor(text: $profile.userPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 50)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                }
            } header: {
                Text("Prompt")
            } footer: {
                Text("The system prompt sets the behaviour; the message goes along with every screenshot. For the menu bar letter to work, ask for the answer letter on the first line.")
                    .foregroundStyle(.secondary)
            }

            Section("Output") {
                Picker("Menu bar shows", selection: $profile.menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases) { Text($0.displayName).tag($0) }
                }
                LabeledContent("Shortcut for this profile") {
                    ShortcutRecorder(combo: $profile.hotkey,
                                     isRefused: model.refusedShortcuts.contains(profile.id.uuidString),
                                     conflictsWith: { ShortcutConflicts.find($0, in: store.settings, excluding: profile.id.uuidString) })
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { maxTokensText = profile.maxTokens.map(String.init) ?? "8192" }
    }

    private var modelChoices: [String] {
        guard let provider else { return [] }
        var ids = provider.cachedModels.map(\.id)
        for m in provider.preset.suggestedModels where !ids.contains(m) { ids.insert(m, at: 0) }
        return ids
    }

    private var effortHelp: String {
        switch provider?.kind ?? .anthropic {
        case .anthropic:
            return "Effort controls how hard Claude thinks (adaptive thinking). Default lets the model decide. Unlimited uses the model's maximum output (up to 128k) and always streams."
        case .openAICompatible:
            return "Effort is sent as reasoning_effort — only reasoning models use it. Unlimited sends no max-token limit at all."
        }
    }

    private func fetchModels() async {
        guard let provider else { return }
        fetching = true
        fetchError = nil
        defer { fetching = false }
        do {
            let profileID = profile.id
            let models = try await LLMClientFactory.make(for: provider, apiKey: Keychain.apiKey(for: provider)).listModels()
            store.setCachedModels(models, forProvider: provider.id)
            if let pick = models.preferredForVision { store.setModelIfEmpty(pick.id, forProfile: profileID) }
        } catch {
            fetchError = error.localizedDescription
        }
    }
}

// MARK: - Providers

struct ProvidersPane: View {
    @ObservedObject var store: SettingsStore
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.settings.providers) { provider in
                        HStack(spacing: 10) {
                            IconTile(symbol: provider.preset.symbol, color: .purple, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(provider.name)
                                Text(provider.preset.shortName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if provider.preset.requiresKey && (Keychain.apiKey(for: provider) ?? "").isEmpty {
                                Image(systemName: "key.slash").foregroundStyle(.orange).help("No API key")
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(provider.id)
                    }
                }
                Divider()
                HStack(spacing: 2) {
                    Menu {
                        ForEach(ProviderPreset.allCases) { preset in
                            Button { add(preset) } label: { Label(preset.displayName, systemImage: preset.symbol) }
                        }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Button { delete() } label: { Image(systemName: "minus") }
                        .disabled(selection == nil || store.settings.providers.count <= 1)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 300)

            Group {
                if let idx = store.settings.providers.firstIndex(where: { $0.id == selection }) {
                    ProviderEditor(provider: $store.settings.providers[idx], store: store)
                        .id(store.settings.providers[idx].id)
                } else {
                    Text("Select a provider").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = store.settings.providers.first?.id } }
    }

    private func add(_ preset: ProviderPreset) {
        let p = ProviderConfig(name: preset.shortName, preset: preset)
        store.settings.providers.append(p)
        selection = p.id
    }

    private func delete() {
        guard let id = selection, store.settings.providers.count > 1 else { return }
        if let p = store.settings.providers.first(where: { $0.id == id }) { Keychain.setAPIKey(nil, for: p) }
        store.settings.providers.removeAll { $0.id == id }
        let fallback = store.settings.providers.first?.id
        for i in store.settings.profiles.indices where store.settings.profiles[i].providerID == id {
            store.settings.profiles[i].providerID = fallback
        }
        selection = fallback
    }
}

struct ProviderEditor: View {
    @Binding var provider: ProviderConfig
    let store: SettingsStore
    @State private var apiKey = ""
    @State private var revealKey = false
    @State private var testState: TestState = .idle

    enum TestState: Equatable { case idle, testing, ok(Int), failed(String) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    IconTile(symbol: provider.preset.symbol, color: .purple, size: 34)
                    VStack(alignment: .leading) {
                        TextField("Name", text: $provider.name).textFieldStyle(.roundedBorder).font(.title3)
                            .labelsHidden().multilineTextAlignment(.leading)
                        Text(provider.preset.helpText).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                Picker("Type", selection: Binding(get: { provider.preset }, set: { newPreset in
                    if provider.baseURL == provider.preset.defaultBaseURL { provider.baseURL = newPreset.defaultBaseURL }
                    provider.preset = newPreset
                    provider.cachedModels = []
                })) {
                    ForEach(ProviderPreset.allCases) { Label($0.displayName, systemImage: $0.symbol).tag($0) }
                }
                TextField("Base URL", text: $provider.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                LabeledContent("API key") {
                    HStack {
                        Group {
                            if revealKey {
                                TextField(provider.preset.keyPlaceholder, text: $apiKey)
                            } else {
                                SecureField(provider.preset.keyPlaceholder, text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: apiKey) { _, new in Keychain.setAPIKey(new, for: provider) }
                        Button { revealKey.toggle() } label: { Image(systemName: revealKey ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless)
                    }
                }
                if let url = provider.preset.keyURL {
                    Link("Get an API key →", destination: url).font(.callout)
                }

                LabeledContent("Timeout") {
                    Stepper("\(Int(provider.timeoutSeconds)) s", value: $provider.timeoutSeconds, in: 15...1800, step: 15)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Keys are stored in your macOS Keychain, never in the settings file.").foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button {
                        Task { await test() }
                    } label: {
                        Label("Test connection & load models", systemImage: "bolt.horizontal.circle")
                    }
                    .disabled(testState == .testing)
                    Spacer()
                    switch testState {
                    case .idle: EmptyView()
                    case .testing: ProgressView().controlSize(.small)
                    case .ok(let n): Label("Connected · \(n) models", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                if case .failed(let msg) = testState {
                    Text(msg).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if !provider.cachedModels.isEmpty {
                    DisclosureGroup("Available models (\(provider.cachedModels.count))") {
                        ForEach(provider.cachedModels) { m in
                            HStack {
                                Text(m.id).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                if let max = m.maxOutputTokens {
                                    Text("max \(max.compactTokens) out").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKey = Keychain.apiKey(for: provider) ?? "" }
    }

    private func test() async {
        testState = .testing
        do {
            let id = provider.id
            let models = try await LLMClientFactory.make(for: provider, apiKey: apiKey).listModels()
            store.setCachedModels(models, forProvider: id)
            testState = .ok(models.count)
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }
}
