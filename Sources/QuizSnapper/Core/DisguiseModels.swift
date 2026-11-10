import Foundation

/// What the menu bar icon pretends to be.
enum DisguiseStyle: String, Codable, CaseIterable, Identifiable {
    case weather, battery, wifi, inputSource, resourceMonitor, vpn, cloudSync, customImage, customSymbol, customText, invisible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weather: return "Weather"
        case .battery: return "Battery"
        case .wifi: return "Wi‑Fi"
        case .inputSource: return "Keyboard"
        case .resourceMonitor: return "Resource monitor"
        case .vpn: return "VPN"
        case .cloudSync: return "iCloud Sync"
        case .customImage: return "Your image / app"
        case .customSymbol: return "Any symbol"
        case .customText: return "Text"
        case .invisible: return "Invisible"
        }
    }

    var subtitle: String {
        switch self {
        case .weather: return "“The forecast couldn't be loaded”"
        case .battery: return "Your real battery level, live"
        case .wifi: return "Wi‑Fi menu with a working switch"
        case .inputSource: return "Real layouts — and it switches them"
        case .resourceMonitor: return "Live CPU & memory, like iStat"
        case .vpn: return "“Not connected”, connect fails"
        case .cloudSync: return "“iCloud Drive is up to date”"
        case .customImage: return "Teams, Notion… or any PNG"
        case .customSymbol: return "Any SF Symbol by name"
        case .customText: return "A short label, e.g. “RO”"
        case .invisible: return "An empty gap in the menu bar"
        }
    }

    /// SF Symbol used for the picker preview.
    var previewSymbol: String {
        switch self {
        case .weather: return "cloud.sun.fill"
        case .battery: return "battery.75percent"
        case .wifi: return "wifi"
        case .inputSource: return "keyboard"
        case .resourceMonitor: return "cpu"
        case .vpn: return "network.badge.shield.half.filled"
        case .cloudSync: return "icloud"
        case .customImage: return "app.badge"
        case .customSymbol: return "star.square.on.square"
        case .customText: return "textformat"
        case .invisible: return "eye.slash"
        }
    }

    /// The fake menu a style shows by default.
    var defaultMenu: FakeMenuKind {
        switch self {
        case .weather: return .weather
        case .battery: return .battery
        case .wifi: return .wifi
        case .inputSource: return .inputSource
        case .resourceMonitor: return .resourceMonitor
        case .vpn: return .vpn
        case .cloudSync: return .cloudSync
        case .customImage, .customSymbol, .customText, .invisible: return .none
        }
    }

    var hasChoosableMenu: Bool { defaultMenu == .none }

    /// How this theme signals "working" and "answer ready" when left on Themed.
    var themedWorking: String {
        switch self {
        case .weather: return "Clouds roll in"
        case .battery: return "No change"
        case .wifi: return "Signal drops to one bar"
        case .inputSource: return "No change"
        case .resourceMonitor: return "No change (CPU moves anyway)"
        case .vpn: return "Badge shows “···”"
        case .cloudSync: return "Cloud shows syncing arrows"
        default: return "Icon dims"
        }
    }

    var themedReady: String {
        switch self {
        case .weather: return "Turns sunny"
        case .battery: return "Charging bolt appears"
        case .wifi: return "Signal goes from 2 bars to full"
        case .inputSource: return "Tiny dot next to the layout"
        case .resourceMonitor: return "A spike in the CPU graph"
        case .vpn: return "Badge turns solid (“connected”)"
        case .cloudSync: return "Cloud shows a checkmark"
        default: return "Tiny dot next to the icon"
        }
    }
}

/// What appears when someone clicks the disguised icon normally.
enum FakeMenuKind: String, Codable, CaseIterable, Identifiable {
    case none, weather, battery, wifi, inputSource, resourceMonitor, vpn, cloudSync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Nothing (click does nothing)"
        case .weather: return "Weather unavailable"
        case .battery: return "Battery details"
        case .wifi: return "Wi‑Fi"
        case .inputSource: return "Keyboard layouts"
        case .resourceMonitor: return "CPU & memory details"
        case .vpn: return "VPN"
        case .cloudSync: return "iCloud Drive status"
        }
    }
}

/// The secret way to open the real QuizSnapper panel while disguised.
enum RevealGesture: String, Codable, CaseIterable, Identifiable {
    case optionClick, commandClick, controlClick, shiftClick, rightClick, optionCommandClick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionClick: return "⌥ Option‑click"
        case .commandClick: return "⌘ Command‑click"
        case .controlClick: return "⌃ Control‑click"
        case .shiftClick: return "⇧ Shift‑click"
        case .rightClick: return "Right‑click"
        case .optionCommandClick: return "⌥⌘ Option‑Command‑click"
        }
    }
}

/// How the icon changes while QuizSnapper is working / when an answer is ready.
enum StateIconMode: String, Codable, CaseIterable, Identifiable {
    case themed, unchanged, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .themed: return "Theme's own signal"
        case .unchanged: return "No change"
        case .custom: return "Custom icon"
        }
    }
}

struct CustomIcon: Codable, Identifiable, Hashable {
    var id = UUID()
    var fileName: String
    var name: String
    /// Template icons are recoloured to match the menu bar (black/white); app icons keep their colours.
    var isTemplate = true

    init(fileName: String, name: String, isTemplate: Bool) {
        self.fileName = fileName
        self.name = name
        self.isTemplate = isTemplate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fileName = try c.decode(String.self, forKey: .fileName)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Icon"
        isTemplate = try c.decodeIfPresent(Bool.self, forKey: .isTemplate) ?? true
    }
}

struct DisguiseSettings: Codable, Equatable {
    var enabled = false
    var style: DisguiseStyle = .weather
    /// When on, a plain click shows the fake menu and only the reveal gesture opens QuizSnapper.
    var requireRevealGesture = true
    var revealGesture: RevealGesture = .optionClick
    /// Show the answer letters next to the disguise (gives the game away — off by default).
    var showLetters = false
    /// Don't show QuizSnapper in the Dock / ⌘-Tab when its windows are open.
    var hideFromDock = true

    // State indicators
    var workingIconMode: StateIconMode = .themed
    var workingIconID: UUID?
    var readyIconMode: StateIconMode = .themed
    var readyIconID: UUID?
    /// 0 = the "ready" signal stays until you open QuizSnapper (or hide the answer).
    var readyTimeoutSeconds: Double = 0

    // Style options
    var weatherLocation = "Bucharest"
    var weatherShowTemperature = false
    var weatherTemperature = "18°"
    var batteryShowPercentage = false
    var wifiNetworkName = "Home"
    var vpnName = "Work VPN"
    var monitorShowCPU = true
    var monitorShowMemory = true
    var monitorShowGraph = true
    var customIcons: [CustomIcon] = []
    var selectedCustomIconID: UUID?
    var customSymbol = "lightbulb"
    var customText = "RO"
    var customMenu: FakeMenuKind = .none

    init() {}

    init(from decoder: Decoder) throws {
        let d = DisguiseSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? def }
        enabled = v(.enabled, d.enabled)
        style = v(.style, d.style)
        requireRevealGesture = v(.requireRevealGesture, d.requireRevealGesture)
        revealGesture = v(.revealGesture, d.revealGesture)
        showLetters = v(.showLetters, d.showLetters)
        hideFromDock = v(.hideFromDock, d.hideFromDock)
        workingIconMode = v(.workingIconMode, d.workingIconMode)
        workingIconID = try? c.decodeIfPresent(UUID.self, forKey: .workingIconID)
        readyIconMode = v(.readyIconMode, d.readyIconMode)
        readyIconID = try? c.decodeIfPresent(UUID.self, forKey: .readyIconID)
        readyTimeoutSeconds = v(.readyTimeoutSeconds, d.readyTimeoutSeconds)
        weatherLocation = v(.weatherLocation, d.weatherLocation)
        weatherShowTemperature = v(.weatherShowTemperature, d.weatherShowTemperature)
        weatherTemperature = v(.weatherTemperature, d.weatherTemperature)
        batteryShowPercentage = v(.batteryShowPercentage, d.batteryShowPercentage)
        wifiNetworkName = v(.wifiNetworkName, d.wifiNetworkName)
        vpnName = v(.vpnName, d.vpnName)
        monitorShowCPU = v(.monitorShowCPU, d.monitorShowCPU)
        monitorShowMemory = v(.monitorShowMemory, d.monitorShowMemory)
        monitorShowGraph = v(.monitorShowGraph, d.monitorShowGraph)
        customIcons = v(.customIcons, d.customIcons)
        selectedCustomIconID = try? c.decodeIfPresent(UUID.self, forKey: .selectedCustomIconID)
        customSymbol = v(.customSymbol, d.customSymbol)
        customText = v(.customText, d.customText)
        customMenu = v(.customMenu, d.customMenu)
    }

    var activeMenu: FakeMenuKind { style.hasChoosableMenu ? customMenu : style.defaultMenu }

    func icon(_ id: UUID?) -> CustomIcon? { customIcons.first { $0.id == id } }

    var selectedCustomIcon: CustomIcon? { icon(selectedCustomIconID) ?? customIcons.first }
}
