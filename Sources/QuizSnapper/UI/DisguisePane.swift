import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DisguisePane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var engine: DisguiseEngine
    @State private var uploadError: String?
    @State private var previewState: PreviewState = .idle

    enum PreviewState: String, CaseIterable, Identifiable {
        case idle = "Normal", working = "Working", ready = "Answer ready", flash = "Answer flash"
        var id: String { rawValue }
        var engineState: DisguiseEngine.IndicatorState {
            switch self {
            case .idle: return .idle
            case .working: return .working
            case .ready, .flash: return .ready
            }
        }
    }

    private var d: Binding<DisguiseSettings> { $store.settings.disguise }
    private var ds: DisguiseSettings { store.settings.disguise }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(symbol: "theatermasks.fill", color: .indigo, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: d.enabled) {
                            Text("Disguise the menu bar icon").font(.headline)
                        }
                        .toggleStyle(.switch)
                        Text("QuizSnapper's icon turns into something ordinary — weather, battery, a CPU meter, Teams… Clicking it shows a convincing fake menu; only your secret click opens QuizSnapper.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                MenuBarPreview(engine: engine, settings: ds, state: previewState.engineState,
                               flashing: previewState == .flash)
                Picker("Preview", selection: $previewState) {
                    ForEach(PreviewState.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Pretend to be") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    ForEach(DisguiseStyle.allCases) { style in
                        StyleCard(style: style, selected: ds.style == style) { store.settings.disguise.style = style }
                    }
                }
                .padding(.vertical, 4)
            }

            styleOptions
            indicatorSection
            iconLibrary

            Section {
                Toggle("Plain click shows the fake menu", isOn: d.requireRevealGesture)
                Picker(ds.requireRevealGesture ? "Open QuizSnapper with" : "Show the fake menu with", selection: d.revealGesture) {
                    ForEach(RevealGesture.allCases) { Text($0.title).tag($0) }
                }
                if ds.revealGesture == .commandClick || ds.revealGesture == .optionCommandClick {
                    Label("macOS uses ⌘ with the mouse to rearrange menu bar icons, so ⌘‑clicks can get swallowed. ⌥‑click or ⌃‑click is more reliable.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            } header: {
                Text("Secret click")
            } footer: {
                Text((ds.requireRevealGesture
                     ? "Anyone clicking the icon sees the fake menu. \(ds.revealGesture.title) opens the real QuizSnapper panel. Global shortcuts keep working as usual."
                     : "A plain click opens QuizSnapper; \(ds.revealGesture.title) shows the fake menu.")
                     + " Forgot it? Open QuizSnapper again from Spotlight or Finder — that always opens Settings.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep QuizSnapper out of the Dock and ⌘‑Tab", isOn: d.hideFromDock)
                Toggle("Show answer letters next to the disguise", isOn: d.showLetters)
                LabeledContent("Quick on/off shortcut") {
                    ShortcutRecorder(
                        combo: Binding(get: { store.settings.shortcut(.toggleDisguise) },
                                       set: { store.settings.shortcuts[ShortcutAction.toggleDisguise.rawValue] = $0 }),
                        conflictsWith: { ShortcutConflicts.find($0, in: store.settings, excluding: ShortcutAction.toggleDisguise.rawValue) })
                }
            } header: {
                Text("While disguised")
            } footer: {
                Text("Tip: hold ⌘ and drag the icon to move it next to the real system icons. Using the battery disguise? Hide the real one in System Settings → Control Center → Battery.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            engine.refreshLiveData()
            engine.forceStatsSampling = true
        }
        .onDisappear { engine.forceStatsSampling = false }
    }

    // MARK: Style options

    @ViewBuilder private var styleOptions: some View {
        let style = ds.style
        Section {
            switch style {
            case .weather:
                TextField("Location shown in the menu", text: d.weatherLocation)
                Toggle("Show a temperature next to the icon", isOn: d.weatherShowTemperature)
                if ds.weatherShowTemperature { TextField("Temperature", text: d.weatherTemperature) }
                note("Clicking shows “Weather Unavailable”. Try Again spins for a few seconds and fails again; Open Weather launches the real Weather app.")
            case .battery:
                Toggle("Show percentage", isOn: d.batteryShowPercentage)
                LabeledContent("Right now") {
                    Text("\(engine.battery.percent)% · \(engine.battery.onAC ? "Power Adapter" : "Battery")\(engine.battery.isCharging ? " · Charging" : "")")
                        .foregroundStyle(.secondary)
                }
                note("Uses your Mac's real battery level and charging state. Battery Settings… opens the real settings.")
                if !engine.battery.hasBattery {
                    Label("This Mac has no battery, so the menu shows a full battery on Power Adapter — a desktop Mac doesn't normally show a battery icon. Consider another disguise.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            case .wifi:
                TextField("Known network name", text: d.wifiNetworkName)
                note("The Wi‑Fi switch in the menu really turns the icon to “off” (it doesn't touch your actual Wi‑Fi).")
            case .inputSource:
                LabeledContent("Current layout") {
                    HStack(spacing: 6) {
                        if let icon = engine.keyboard.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                        Text(engine.keyboard.name).foregroundStyle(.secondary)
                    }
                }
                note("Fully functional: the menu lists your real keyboard layouts and switching works. The icon follows the active layout.")
            case .resourceMonitor:
                Toggle("Show CPU %", isOn: d.monitorShowCPU)
                Toggle("Show memory %", isOn: d.monitorShowMemory)
                Toggle("Show CPU graph", isOn: d.monitorShowGraph)
                LabeledContent("Right now") {
                    Text("CPU \(Int((engine.stats.cpu * 100).rounded()))% · Memory \(SystemStats.formatBytes(engine.stats.memoryUsed)) of \(SystemStats.formatBytes(engine.stats.memoryTotal))")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                note("Live data, updated every 2 seconds — the same numbers Activity Monitor shows. The menu has a CPU chart, memory pressure and an Open Activity Monitor item.")
            case .vpn:
                TextField("VPN name", text: d.vpnName)
                note("The menu shows “Not Connected”. Turning it on spins for a few seconds, then reports that the server did not respond.")
            case .cloudSync:
                note("Shows “iCloud Drive — Up to date” with a recent sync time. Open iCloud Drive opens the real folder.")
            case .customImage:
                iconPicker(title: "Icon", selection: d.selectedCustomIconID, allowNone: false)
                note("Pick an icon from your library below — upload one or grab an installed app's icon (Teams, Notion, Slack…).")
                customMenuPicker
            case .customSymbol:
                HStack {
                    TextField("SF Symbol name", text: d.customSymbol)
                    if let img = DisguiseEngine.symbol(ds.customSymbol) {
                        Image(nsImage: img).renderingMode(.template)
                    } else {
                        Image(systemName: "questionmark.square.dashed").foregroundStyle(.red)
                    }
                }
                note("Any symbol from Apple's SF Symbols, e.g. “lightbulb”, “bolt.horizontal”, “moon.fill”, “headphones”, “externaldrive”.")
                customMenuPicker
            case .customText:
                TextField("Text", text: d.customText)
                note("Short labels look most natural: a language code (RO, EN), a temperature (21°), a time zone (UTC)…")
                customMenuPicker
            case .invisible:
                note("A narrow empty gap — invisible unless you know where to click. Your secret click still opens QuizSnapper.")
                customMenuPicker
            }
        } header: {
            Text("\(style.title) options")
        }
    }

    // MARK: Indicators

    private var indicatorSection: some View {
        Section {
            Picker("While working", selection: d.workingIconMode) {
                ForEach(StateIconMode.allCases) { Text(label($0, themed: ds.style.themedWorking)).tag($0) }
            }
            if ds.workingIconMode == .custom {
                iconPicker(title: "Working icon", selection: d.workingIconID, allowNone: false)
            }
            Picker("When the answer is ready", selection: d.readyIconMode) {
                ForEach(StateIconMode.allCases) { Text(label($0, themed: ds.style.themedReady)).tag($0) }
            }
            if ds.readyIconMode == .custom {
                iconPicker(title: "Ready icon", selection: d.readyIconID, allowNone: false)
            }
            Picker("Ready signal lasts", selection: d.readyTimeoutSeconds) {
                Text("Until I open QuizSnapper").tag(0.0)
                Text("10 seconds").tag(10.0)
                Text("30 seconds").tag(30.0)
                Text("1 minute").tag(60.0)
                Text("5 minutes").tag(300.0)
            }
            Picker("Flash the answer itself", selection: $store.settings.answerFlashSeconds) {
                Text("Off").tag(0.0)
                Text("1 second").tag(1.0)
                Text("2 seconds").tag(2.0)
                Text("3 seconds").tag(3.0)
                Text("5 seconds").tag(5.0)
            }
            Toggle(isOn: $store.settings.autoCopyFillInAnswers) {
                Text("Fill‑in answers go to the clipboard")
                Text("Questions with text boxes instead of options: every value, in order, joined with “; ” — ready to paste.")
            }
            Toggle("Copy the whole answer to the clipboard when it's ready", isOn: $store.settings.copyAnswerToClipboard)
        } header: {
            Text("Status signals")
        } footer: {
            Text("Each theme has its own natural-looking change (switch the preview above to see it). Or pick a custom icon for just one state — e.g. normal Wi‑Fi, but a Teams icon when the answer is ready. Hiding the answer overlay also clears the ready signal.\n\nFlashing swaps the disguise for the bare answer letters for a moment, then puts it straight back — a clipboard glyph instead when the answer was text that got copied.")
                .foregroundStyle(.secondary)
        }
    }

    private func label(_ mode: StateIconMode, themed: String) -> String {
        mode == .themed ? "Theme: \(themed)" : mode.title
    }

    @ViewBuilder
    private func iconPicker(title: String, selection: Binding<UUID?>, allowNone: Bool) -> some View {
        if ds.customIcons.isEmpty {
            LabeledContent(title) {
                Text("Add icons to the library below first").foregroundStyle(.orange)
            }
        } else {
            Picker(title, selection: selection) {
                if allowNone || selection.wrappedValue == nil { Text("Choose…").tag(UUID?.none) }
                ForEach(ds.customIcons) { icon in
                    Label {
                        Text(icon.name)
                    } icon: {
                        if let img = DisguiseEngine.loadCustomIcon(icon) {
                            Image(nsImage: img).renderingMode(icon.isTemplate ? .template : .original)
                        }
                    }
                    .tag(Optional(icon.id))
                }
            }
        }
    }

    // MARK: Icon library

    private var iconLibrary: some View {
        Section {
            if ds.customIcons.isEmpty {
                note("No icons yet. Upload images or use an installed app's icon — they can be the main disguise or appear only while working / when the answer is ready.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(ds.customIcons) { icon in
                            CustomIconTile(icon: icon,
                                           selected: ds.style == .customImage && ds.selectedCustomIcon?.id == icon.id,
                                           onSelect: {
                                               store.settings.disguise.selectedCustomIconID = icon.id
                                               store.settings.disguise.style = .customImage
                                           },
                                           onToggleTemplate: { toggleTemplate(icon) },
                                           onDelete: { delete(icon) })
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            let known = KnownApps.installed.filter { app in !ds.customIcons.contains { $0.name == app.name } }
            if !known.isEmpty {
                LabeledContent("Installed apps") {
                    HStack(spacing: 6) {
                        ForEach(known.prefix(8)) { app in
                            Button {
                                addAppIcon(at: app.url, name: app.name)
                            } label: {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                            .help("Add \(app.name)'s icon")
                        }
                    }
                }
            }
            HStack {
                Button("Upload image…") { upload() }
                Button("Use any app's icon…") { pickApp() }
                Spacer()
            }
            if let uploadError { Text(uploadError).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Icon library")
        } footer: {
            Text("Click an icon to use it as the disguise. Right-click to switch between “match menu bar colour” (monochrome) and original colours. PNG, PDF, TIFF, HEIC, ICNS, SVG.")
                .foregroundStyle(.secondary)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var customMenuPicker: some View {
        Picker("When clicked, show", selection: d.customMenu) {
            ForEach(FakeMenuKind.allCases) { Text($0.title).tag($0) }
        }
    }

    // MARK: Library actions

    private func upload() {
        uploadError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .pdf, .tiff, .heic, .icns, .svg, .gif, .bmp]
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more images for the menu bar"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let image = NSImage(contentsOf: url) else {
                uploadError = "Couldn't read \(url.lastPathComponent)."
                continue
            }
            let fileName = UUID().uuidString + "." + url.pathExtension.lowercased()
            do {
                try FileManager.default.copyItem(at: url, to: AppPaths.iconsDir.appendingPathComponent(fileName))
                add(CustomIcon(fileName: fileName, name: url.deletingPathExtension().lastPathComponent,
                               isTemplate: Self.looksMonochrome(image)))
            } catch {
                uploadError = error.localizedDescription
            }
        }
    }

    private func pickApp() {
        uploadError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Pick an app — its icon goes into your library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addAppIcon(at: url, name: url.deletingPathExtension().lastPathComponent)
    }

    private func addAppIcon(at url: URL, name: String) {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let fileName = UUID().uuidString + ".png"
        do {
            try png.write(to: AppPaths.iconsDir.appendingPathComponent(fileName))
            add(CustomIcon(fileName: fileName, name: name, isTemplate: false))
        } catch {
            uploadError = error.localizedDescription
        }
    }

    private func add(_ icon: CustomIcon) {
        store.settings.disguise.customIcons.append(icon)
        if store.settings.disguise.selectedCustomIconID == nil { store.settings.disguise.selectedCustomIconID = icon.id }
    }

    private func toggleTemplate(_ icon: CustomIcon) {
        if let i = store.settings.disguise.customIcons.firstIndex(where: { $0.id == icon.id }) {
            store.settings.disguise.customIcons[i].isTemplate.toggle()
        }
    }

    private func delete(_ icon: CustomIcon) {
        try? FileManager.default.removeItem(at: AppPaths.iconsDir.appendingPathComponent(icon.fileName))
        var s = store.settings.disguise
        s.customIcons.removeAll { $0.id == icon.id }
        if s.selectedCustomIconID == icon.id { s.selectedCustomIconID = s.customIcons.first?.id }
        if s.workingIconID == icon.id { s.workingIconID = nil; s.workingIconMode = .themed }
        if s.readyIconID == icon.id { s.readyIconID = nil; s.readyIconMode = .themed }
        store.settings.disguise = s
    }

    /// Black/white/transparent images become template icons (they follow the menu bar colour).
    static func looksMonochrome(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 96,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return true }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 24, height: 24))
        let px = data.bindMemory(to: UInt8.self, capacity: 24 * 24 * 4)
        for i in 0..<(24 * 24) {
            let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2]), a = Int(px[i * 4 + 3])
            if a > 40 && (abs(r - g) > 24 || abs(g - b) > 24 || abs(r - b) > 24) { return false }
        }
        return true
    }
}

// MARK: - Well-known apps

struct KnownApp: Identifiable {
    let id: String
    let name: String
    let url: URL
}

enum KnownApps {
    private static let candidates: [(String, String)] = [
        ("com.microsoft.teams2", "Microsoft Teams"), ("com.microsoft.teams", "Microsoft Teams"),
        ("notion.id", "Notion"), ("com.tinyspeck.slackmacgap", "Slack"), ("com.hnc.Discord", "Discord"),
        ("com.spotify.client", "Spotify"), ("us.zoom.xos", "Zoom"), ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("com.getdropbox.dropbox", "Dropbox"), ("com.microsoft.OneDrive", "OneDrive"),
        ("com.google.drivefs", "Google Drive"), ("com.1password.1password", "1Password"),
        ("com.microsoft.Outlook", "Outlook"), ("com.viber.osx", "Viber"), ("com.logi.optionsplus", "Logi Options+"),
        ("com.philandro.anydesk", "AnyDesk"), ("com.goodnotesapp.x", "Goodnotes"),
    ]

    static var installed: [KnownApp] {
        var seen = Set<String>()
        return candidates.compactMap { id, name in
            guard !seen.contains(name), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            seen.insert(name)
            return KnownApp(id: id, name: name, url: url)
        }
    }
}

// MARK: - Pieces

/// A strip that looks like the right side of the menu bar, with the disguised icon among real-looking neighbours.
private struct MenuBarPreview: View {
    @ObservedObject var engine: DisguiseEngine
    let settings: DisguiseSettings
    let state: DisguiseEngine.IndicatorState
    var flashing = false

    var body: some View {
        let look = engine.appearance(for: settings, state: state)
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 14) {
                Spacer()
                HStack(spacing: 4) {
                    if flashing {
                        Text("A,C").font(.system(size: 13, weight: .semibold, design: .monospaced))
                    } else if settings.enabled {
                        if look.imageTrailing && !look.title.isEmpty { Text(look.title) }
                        if let img = look.image {
                            Image(nsImage: img).renderingMode(img.isTemplate ? .template : .original)
                        }
                        if !look.imageTrailing && !look.title.isEmpty { Text(look.title) }
                    } else {
                        Image(systemName: "text.viewfinder")
                    }
                }
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.18)))
                Image(systemName: "wifi")
                Image(nsImage: DisguiseEngine.batteryImage(percent: 80)).renderingMode(.template)
                Image(systemName: "switch.2")
                Text(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            )
            Text(flashing
                 ? "Just for a moment when the answer lands — then the disguise is back."
                 : (settings.enabled ? "The highlighted icon is QuizSnapper." : "Disguise is off — QuizSnapper shows its own icon."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct StyleCard: View {
    let style: DisguiseStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: style.previewSymbol)
                    .font(.system(size: 16))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(style.title).font(.system(size: 12.5, weight: .semibold))
                    Text(style.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CustomIconTile: View {
    let icon: CustomIcon
    let selected: Bool
    let onSelect: () -> Void
    let onToggleTemplate: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                VStack(spacing: 4) {
                    if let img = DisguiseEngine.loadCustomIcon(icon) {
                        Image(nsImage: img).renderingMode(icon.isTemplate ? .template : .original)
                            .frame(width: 40, height: 28)
                    }
                    Text(icon.name).font(.caption2).lineLimit(1).frame(width: 64)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(icon.isTemplate ? "Use original colours" : "Match menu bar colour", action: onToggleTemplate)
                Button("Delete", role: .destructive, action: onDelete)
            }
            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
        .onHover { hovering = $0 }
    }
}
