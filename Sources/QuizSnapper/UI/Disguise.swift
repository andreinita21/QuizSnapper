import AppKit
import Carbon
import Darwin
import IOKit.ps
import SwiftUI

// MARK: - Live system data

struct BatteryInfo: Equatable {
    var percent = 100
    var isCharging = false
    var onAC = true
    var hasBattery = false
    var minutesRemaining: Int?

    static func read() -> BatteryInfo {
        var info = BatteryInfo()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return info }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            info.hasBattery = true
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 100
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            info.percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            info.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            info.onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            if let tte = desc[kIOPSTimeToEmptyKey] as? Int, tte > 0, !info.onAC { info.minutesRemaining = tte }
        }
        return info
    }
}

/// Real CPU and memory usage (same sources Activity Monitor uses).
struct SystemStats: Equatable {
    var cpu: Double = 0          // 0…1
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var compressed: UInt64 = 0
    var history: [Double] = Array(repeating: 0, count: 12)

    var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }

    static func formatBytes(_ b: UInt64) -> String {
        String(format: "%.1f GB", Double(b) / 1_073_741_824)
    }
}

final class SystemSampler {
    private var previous: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    func sample(into stats: inout SystemStats) {
        // CPU
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let t = (user: load.cpu_ticks.0, system: load.cpu_ticks.1, idle: load.cpu_ticks.2, nice: load.cpu_ticks.3)
            if let p = previous {
                let user = Double(t.user &- p.user) + Double(t.nice &- p.nice)
                let system = Double(t.system &- p.system)
                let idle = Double(t.idle &- p.idle)
                let total = user + system + idle
                if total > 0 {
                    stats.cpuUser = user / total
                    stats.cpuSystem = system / total
                    stats.cpu = (user + system) / total
                }
            }
            previous = t
        }
        stats.history = Array((stats.history + [stats.cpu]).suffix(12))

        // Memory ("Memory Used" = app + wired + compressed)
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let vmr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vmr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let app = UInt64(vm.internal_page_count) &- UInt64(vm.purgeable_count)
            stats.compressed = UInt64(vm.compressor_page_count) * page
            stats.memoryUsed = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        }
    }
}

struct KeyboardLayout: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let abbreviation: String
    let source: TISInputSource

    private static func prop<T>(_ s: TISInputSource, _ key: CFString) -> T? {
        guard let p = TISGetInputSourceProperty(s, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue() as? T
    }

    init(_ source: TISInputSource) {
        self.source = source
        id = Self.prop(source, kTISPropertyInputSourceID) ?? UUID().uuidString
        name = Self.prop(source, kTISPropertyLocalizedName) ?? "Keyboard"
        if let url: URL = Self.prop(source, kTISPropertyIconImageURL), let img = NSImage(contentsOf: url) {
            icon = img
        } else if let p = TISGetInputSourceProperty(source, kTISPropertyIconRef) {
            icon = NSImage(iconRef: OpaquePointer(p))
        } else {
            icon = nil
        }
        let langs: [String] = Self.prop(source, kTISPropertyInputSourceLanguages) ?? []
        let last = id.split(separator: ".").last.map(String.init) ?? name
        if last.uppercased() == last && last.count <= 4 {
            abbreviation = last
        } else if let lang = langs.first {
            abbreviation = String(lang.prefix(2)).uppercased()
        } else {
            abbreviation = String(name.prefix(2)).uppercased()
        }
    }

    static var current: KeyboardLayout {
        KeyboardLayout(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    }

    static var enabled: [KeyboardLayout] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        return list.map(KeyboardLayout.init)
    }

    func select() { TISSelectInputSource(source) }
}

// MARK: - Engine

/// Produces the disguised menu bar icon and the fake menus behind it.
/// Data is real where it can be (battery, CPU/RAM, keyboard layouts) so the disguise holds up.
@MainActor
final class DisguiseEngine: ObservableObject {
    enum IndicatorState { case idle, working, ready }
    enum VPNState { case disconnected, connecting, failed }

    private let store: SettingsStore

    @Published private(set) var battery = BatteryInfo.read()
    @Published private(set) var keyboard = KeyboardLayout.current
    @Published private(set) var stats = SystemStats()
    @Published var wifiOn = true
    @Published var weatherLoading = false
    @Published var weatherLastAttempt: Date?
    @Published var vpnState: VPNState = .disconnected

    private let sampler = SystemSampler()
    private var slowTimer: Timer?
    private var fastTimer: Timer?
    private var inputObserver: NSObjectProtocol?

    init(store: SettingsStore) {
        self.store = store
        var s = SystemStats()
        sampler.sample(into: &s)
        stats = s
        // `.common` mode so values keep updating while a fake menu is open.
        slowTimer = Self.commonTimer(20) { [weak self] in self?.refreshLiveData() }
        fastTimer = Self.commonTimer(2) { [weak self] in self?.sampleStatsIfNeeded() }
        inputObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.keyboard = KeyboardLayout.current }
        }
    }

    private static func commonTimer(_ interval: TimeInterval, _ block: @escaping @MainActor () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in Task { @MainActor in block() } }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private var settings: DisguiseSettings { store.settings.disguise }

    /// Set while the Disguise settings pane or a resource menu is visible.
    var forceStatsSampling = false

    private func sampleStatsIfNeeded() {
        guard forceStatsSampling || (settings.enabled && (settings.style == .resourceMonitor || settings.activeMenu == .resourceMonitor)) else { return }
        var s = stats
        sampler.sample(into: &s)
        stats = s
    }

    func refreshLiveData() {
        let b = BatteryInfo.read()
        if b != battery { battery = b }
        keyboard = KeyboardLayout.current
    }

    // MARK: Icon

    struct Appearance {
        var image: NSImage?
        var title: String
        var accessibilityLabel: String
        var imageTrailing = false
    }

    func appearance(for s: DisguiseSettings? = nil, state: IndicatorState = .idle) -> Appearance {
        let s = s ?? settings
        // Per-state custom icons win over everything (e.g. a Teams icon only when the answer is ready).
        if state == .working, s.workingIconMode == .custom, let icon = s.icon(s.workingIconID),
           let img = Self.loadCustomIcon(icon) {
            return Appearance(image: img, title: "", accessibilityLabel: icon.name)
        }
        if state == .ready, s.readyIconMode == .custom, let icon = s.icon(s.readyIconID),
           let img = Self.loadCustomIcon(icon) {
            return Appearance(image: img, title: "", accessibilityLabel: icon.name)
        }
        let themed: IndicatorState
        switch state {
        case .idle: themed = .idle
        case .working: themed = s.workingIconMode == .themed ? .working : .idle
        case .ready: themed = s.readyIconMode == .themed ? .ready : .idle
        }
        return base(s, themed)
    }

    private func base(_ s: DisguiseSettings, _ state: IndicatorState) -> Appearance {
        switch s.style {
        case .weather:
            let symbol = (weatherLoading || state == .working) ? "cloud" : (state == .ready ? "sun.max" : "cloud.sun")
            return Appearance(image: Self.symbol(symbol), title: s.weatherShowTemperature ? s.weatherTemperature : "",
                              accessibilityLabel: "Weather")
        case .battery:
            let img = (battery.isCharging || state == .ready) ? Self.symbol("battery.100percent.bolt", pointSize: 15)
                                                             : Self.batteryImage(percent: battery.percent)
            return Appearance(image: img, title: s.batteryShowPercentage ? "\(battery.percent)%" : "",
                              accessibilityLabel: "Battery", imageTrailing: true)
        case .wifi:
            let img: NSImage?
            if !wifiOn {
                img = Self.symbol("wifi.slash")
            } else {
                let level: Double = state == .working ? 0.2 : (state == .ready ? 1.0 : 0.5)
                img = Self.symbol("wifi", variable: level)
            }
            return Appearance(image: img, title: "", accessibilityLabel: "Wi‑Fi")
        case .inputSource:
            var img: NSImage
            if let icon = keyboard.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                img = icon
            } else {
                img = Self.textBadge(keyboard.abbreviation)
            }
            if state == .ready { img = Self.withDot(img) }
            return Appearance(image: img, title: "", accessibilityLabel: "Text Input")
        case .resourceMonitor:
            return Appearance(image: Self.monitorImage(stats: stats, settings: s, spike: state == .ready),
                              title: "", accessibilityLabel: "CPU")
        case .vpn:
            let connecting = vpnState == .connecting || state == .working
            let img = Self.textBadge(connecting ? "···" : "VPN", filled: state == .ready)
            return Appearance(image: img, title: "", accessibilityLabel: "VPN")
        case .cloudSync:
            let symbol = state == .working ? "arrow.triangle.2.circlepath.icloud" : (state == .ready ? "checkmark.icloud" : "icloud")
            return Appearance(image: Self.symbol(symbol), title: "", accessibilityLabel: "iCloud")
        case .customImage:
            var img = s.selectedCustomIcon.flatMap { Self.loadCustomIcon($0) } ?? Self.symbol("photo")
            img = decorate(img, state)
            return Appearance(image: img, title: "", accessibilityLabel: s.selectedCustomIcon?.name ?? "Status")
        case .customSymbol:
            let img = Self.symbol(s.customSymbol) ?? Self.symbol("questionmark.square.dashed")
            return Appearance(image: decorate(img, state), title: "", accessibilityLabel: s.customSymbol)
        case .customText:
            let text = s.customText.isEmpty ? " " : s.customText
            return Appearance(image: state == .ready ? Self.dotImage() : nil, title: text,
                              accessibilityLabel: s.customText, imageTrailing: true)
        case .invisible:
            let img = NSImage(size: NSSize(width: 6, height: 16))
            img.isTemplate = true
            return Appearance(image: state == .ready ? Self.dotImage() : img, title: "", accessibilityLabel: "")
        }
    }

    private func decorate(_ img: NSImage?, _ state: IndicatorState) -> NSImage? {
        guard let img else { return nil }
        switch state {
        case .idle: return img
        case .ready: return Self.withDot(img)
        case .working: return Self.dimmed(img)
        }
    }

    // MARK: Drawing helpers

    static func symbol(_ name: String, pointSize: CGFloat = 14, variable: Double? = nil) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let raw = variable.map { NSImage(systemSymbolName: name, variableValue: $0, accessibilityDescription: nil) }
            ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let img = raw?.withSymbolConfiguration(config)
        img?.isTemplate = true
        return img
    }

    /// A battery glyph drawn like the system one, filled to the real level.
    static func batteryImage(percent: Int) -> NSImage {
        let low = percent <= 10
        let img = NSImage(size: NSSize(width: 27, height: 13), flipped: false) { _ in
            let body = NSRect(x: 0.5, y: 0.5, width: 23.5, height: 12)
            NSColor.black.withAlphaComponent(0.4).setStroke()
            let outline = NSBezierPath(roundedRect: body, xRadius: 3.5, yRadius: 3.5)
            outline.lineWidth = 1
            outline.stroke()
            NSColor.black.withAlphaComponent(0.4).setFill()
            NSBezierPath(roundedRect: NSRect(x: 25, y: 4, width: 1.7, height: 5), xRadius: 0.8, yRadius: 0.8).fill()
            let fillWidth = max(2, (body.width - 4) * CGFloat(min(max(percent, 0), 100)) / 100)
            (low ? NSColor.systemRed : NSColor.black).setFill()
            NSBezierPath(roundedRect: NSRect(x: 2.5, y: 2.5, width: fillWidth, height: 8), xRadius: 1.8, yRadius: 1.8).fill()
            return true
        }
        img.isTemplate = !low
        return img
    }

    /// A rounded badge with the text knocked out (like the "ABC" input-source icon). Outline when not filled.
    static func textBadge(_ text: String, filled: Bool = true) -> NSImage {
        let font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let size = NSSize(width: max(18, ceil(textSize.width) + 7), height: 15)
        let img = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3.5, yRadius: 3.5)
            let origin = NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2 + 0.5)
            if filled {
                NSColor.black.setFill()
                path.fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                (text as NSString).draw(at: origin, withAttributes: attrs)
            } else {
                NSColor.black.setStroke()
                path.lineWidth = 1.2
                path.stroke()
                (text as NSString).draw(at: origin, withAttributes: attrs)
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// iStat-style stacked "CPU 12% / MEM 63%" label with an optional mini CPU graph.
    static func monitorImage(stats: SystemStats, settings s: DisguiseSettings, spike: Bool) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        var lines: [String] = []
        if s.monitorShowCPU { lines.append("CPU \(Int((stats.cpu * 100).rounded()))%") }
        if s.monitorShowMemory { lines.append("MEM \(Int((stats.memoryFraction * 100).rounded()))%") }
        if lines.isEmpty && !s.monitorShowGraph { lines = ["CPU \(Int((stats.cpu * 100).rounded()))%"] }
        let textWidth = lines.map { ceil(($0 as NSString).size(withAttributes: attrs).width) }.max() ?? 0
        let graphWidth: CGFloat = s.monitorShowGraph ? 26 : 0
        let gap: CGFloat = (graphWidth > 0 && textWidth > 0) ? 4 : 0
        let size = NSSize(width: max(graphWidth + gap + textWidth, 8), height: 18)

        var history = stats.history
        if spike, !history.isEmpty { history[history.count - 1] = 1.0 }

        let img = NSImage(size: size, flipped: false) { _ in
            if graphWidth > 0 {
                let frame = NSRect(x: 0.5, y: 2.5, width: graphWidth - 1, height: 13)
                NSColor.black.withAlphaComponent(0.35).setStroke()
                NSBezierPath(roundedRect: frame, xRadius: 2, yRadius: 2).stroke()
                let barW = (frame.width - 2) / CGFloat(history.count)
                NSColor.black.setFill()
                for (i, v) in history.enumerated() {
                    let h = max(1, (frame.height - 2) * CGFloat(min(max(v, 0), 1)))
                    NSRect(x: frame.minX + 1 + CGFloat(i) * barW, y: frame.minY + 1, width: max(barW - 0.4, 0.8), height: h).fill()
                }
            }
            let x = graphWidth + gap
            if lines.count == 1 {
                (lines[0] as NSString).draw(at: NSPoint(x: x, y: 4), withAttributes: attrs)
            } else {
                for (i, line) in lines.enumerated() {
                    (line as NSString).draw(at: NSPoint(x: x, y: i == 0 ? 8.5 : -0.5), withAttributes: attrs)
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    static func withDot(_ base: NSImage) -> NSImage {
        let size = NSSize(width: base.size.width + 5, height: max(base.size.height, 14))
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: (rect.height - base.size.height) / 2, width: base.size.width, height: base.size.height))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.width - 3.5, y: rect.height - 4.5, width: 3.5, height: 3.5)).fill()
            return true
        }
        img.isTemplate = base.isTemplate
        return img
    }

    static func dotImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 6, height: 14), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: rect.height - 5, width: 3.5, height: 3.5)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    static func dimmed(_ base: NSImage) -> NSImage {
        let img = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.45)
            return true
        }
        img.isTemplate = base.isTemplate
        return img
    }

    static func loadCustomIcon(_ icon: CustomIcon) -> NSImage? {
        let url = AppPaths.iconsDir.appendingPathComponent(icon.fileName)
        guard let src = NSImage(contentsOf: url) else { return nil }
        let h: CGFloat = icon.isTemplate ? 16 : 17
        let ratio = src.size.height > 0 ? src.size.width / src.size.height : 1
        let size = NSSize(width: min(h * ratio, 28), height: h)
        let img = NSImage(size: size, flipped: false) { rect in
            src.draw(in: rect)
            return true
        }
        img.isTemplate = icon.isTemplate
        return img
    }

    // MARK: Fake menus

    func makeMenu(_ kind: FakeMenuKind) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch kind {
        case .none: return nil
        case .weather: buildWeather(menu)
        case .battery: buildBattery(menu)
        case .wifi: buildWifi(menu)
        case .inputSource: buildInputSource(menu)
        case .resourceMonitor: buildMonitor(menu)
        case .vpn: buildVPN(menu)
        case .cloudSync: buildCloud(menu)
        }
        return menu
    }

    private func viewItem<V: View>(_ view: V, width: CGFloat = 290) -> NSMenuItem {
        let host = NSHostingView(rootView: view.frame(width: width, alignment: .leading))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let item = NSMenuItem()
        item.view = host
        return item
    }

    private func actionItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, handler: action)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func openURL(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    private func openApp(_ bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private func buildWeather(_ menu: NSMenu) {
        menu.addItem(viewItem(WeatherMenuView(engine: self, location: settings.weatherLocation)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Try Again") { [weak self] in self?.retryWeather() })
        menu.addItem(actionItem("Open Weather") { [weak self] in self?.openApp("com.apple.weather") })
    }

    func retryWeather() {
        weatherLoading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 2.5...4.5)) { [weak self] in
            self?.weatherLoading = false
            self?.weatherLastAttempt = Date()
        }
    }

    private func buildBattery(_ menu: NSMenu) {
        battery = BatteryInfo.read()
        menu.addItem(viewItem(BatteryMenuView(battery: battery)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Using Significant Energy"))
        menu.addItem(disabledItem("No Apps Using Significant Energy"))
        menu.addItem(.separator())
        menu.addItem(actionItem("Battery Settings…") { [weak self] in
            self?.openURL("x-apple.systempreferences:com.apple.Battery-Settings.extension")
        })
    }

    private func buildWifi(_ menu: NSMenu) {
        menu.addItem(viewItem(WifiHeaderView(engine: self)))
        if wifiOn {
            menu.addItem(NSMenuItem.sectionHeader(title: "Known Network"))
            menu.addItem(viewItem(WifiNetworkRow(name: settings.wifiNetworkName)))
            menu.addItem(NSMenuItem.sectionHeader(title: "Other Networks"))
            menu.addItem(viewItem(HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Searching…").foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.vertical, 3)))
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Wi‑Fi Settings…") { [weak self] in
            self?.openURL("x-apple.systempreferences:com.apple.wifi-settings-extension")
        })
    }

    private func buildInputSource(_ menu: NSMenu) {
        let current = KeyboardLayout.current.id
        for layout in KeyboardLayout.enabled {
            let item = actionItem(layout.name) { [weak self] in
                layout.select()
                self?.keyboard = KeyboardLayout.current
            }
            if let icon = layout.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            item.state = layout.id == current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Show Emoji & Symbols") { NSApp.orderFrontCharacterPalette(nil) })
        menu.addItem(.separator())
        menu.addItem(actionItem("Open Keyboard Settings…") { [weak self] in
            self?.openURL("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        })
    }

    private func buildMonitor(_ menu: NSMenu) {
        var s = stats
        sampler.sample(into: &s)
        stats = s
        menu.addItem(viewItem(ResourceMenuView(engine: self), width: 300))
        menu.addItem(.separator())
        menu.addItem(actionItem("Open Activity Monitor") { [weak self] in self?.openApp("com.apple.ActivityMonitor") })
    }

    private func buildVPN(_ menu: NSMenu) {
        menu.addItem(viewItem(VPNMenuView(engine: self, name: settings.vpnName)))
        menu.addItem(.separator())
        menu.addItem(actionItem("VPN Settings…") { [weak self] in
            self?.openURL("x-apple.systempreferences:com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension")
        })
    }

    func connectVPN() {
        guard vpnState != .connecting else { return }
        vpnState = .connecting
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 3...5)) { [weak self] in
            self?.vpnState = .failed
        }
    }

    private func buildCloud(_ menu: NSMenu) {
        menu.addItem(viewItem(CloudMenuView()))
        menu.addItem(.separator())
        menu.addItem(actionItem("Open iCloud Drive") {
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"))
        })
        menu.addItem(actionItem("iCloud Settings…") { [weak self] in
            self?.openURL("x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings:icloud")
        })
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
