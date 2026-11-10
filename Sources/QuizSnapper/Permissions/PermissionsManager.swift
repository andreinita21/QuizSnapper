import AppKit
import ScreenCaptureKit
import ServiceManagement
import UserNotifications

enum PermissionStatus: Equatable {
    case granted
    case notDetermined
    case denied
    /// The user enabled it in System Settings but macOS only applies it after a relaunch.
    case needsRelaunch

    var isGranted: Bool { self == .granted }
}

enum PermissionKind: String, CaseIterable, Identifiable {
    case screenRecording, notifications
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .notifications: return "Notifications"
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .notifications: return "bell.badge.fill"
        }
    }

    var isRequired: Bool { self == .screenRecording }

    var explanation: String {
        switch self {
        case .screenRecording:
            return "Needed to take screenshots of the question. QuizSnapper only captures when you press a shortcut — never in the background — and images go only to the AI provider you choose."
        case .notifications:
            return "Optional. Lets QuizSnapper show the answer as a notification (useful when the floating overlay is turned off)."
        }
    }

    var settingsURL: URL {
        switch self {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.andrei.quizsnapper")!
        }
    }
}

/// Tracks the permissions QuizSnapper needs and drives the "grant → verify → next" flow.
///
/// Global shortcuts use Carbon hotkeys, so **no Accessibility / Input Monitoring
/// permission is needed** — only Screen Recording (required) and Notifications (optional).
@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var screenRecording: PermissionStatus = .notDetermined
    @Published private(set) var notifications: PermissionStatus = .notDetermined
    @Published private(set) var launchAtLogin = false
    /// Set after the user clicked "Grant" for screen recording, so we can offer a relaunch if macOS doesn't report it.
    @Published private(set) var screenRecordingRequestedAt: Date?

    private var pollTimer: Timer?
    private let requestedKey = "screenRecordingRequested"

    init() {
        refresh()
    }

    func status(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .screenRecording: return screenRecording
        case .notifications: return notifications
        }
    }

    var allRequiredGranted: Bool { screenRecording.isGranted }

    // MARK: Refresh

    func refresh() {
        if CGPreflightScreenCaptureAccess() {
            screenRecording = .granted
        } else if UserDefaults.standard.bool(forKey: requestedKey) {
            screenRecording = .denied
        } else {
            screenRecording = .notDetermined
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: PermissionStatus
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: status = .granted
            case .denied: status = .denied
            default: status = .notDetermined
            }
            Task { @MainActor in self.notifications = status }
        }

        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Polls once a second (while a permission UI is visible) so the UI flips to ✓ the moment
    /// the user toggles the switch in System Settings.
    private var pollClients = 0

    /// Reference-counted: Onboarding and the Permissions pane can both be open.
    func startPolling() {
        pollClients += 1
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        pollClients = max(0, pollClients - 1)
        guard pollClients == 0 else { return }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Requests

    func request(_ kind: PermissionKind) {
        switch kind {
        case .screenRecording: requestScreenRecording()
        case .notifications: requestNotifications()
        }
    }

    func requestScreenRecording() {
        UserDefaults.standard.set(true, forKey: requestedKey)
        screenRecordingRequestedAt = Date()
        // Registers the app in the Screen Recording list (and shows the system prompt the first time)…
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            // …and take the user straight to the right pane.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSWorkspace.shared.open(PermissionKind.screenRecording.settingsURL)
            }
        }
        refresh()
    }

    func requestNotifications() {
        if notifications == .denied {
            NSWorkspace.shared.open(PermissionKind.notifications.settingsURL)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    /// True a few seconds after the user was sent to System Settings and macOS still reports no access:
    /// on many macOS versions Screen Recording only takes effect after a relaunch.
    var shouldOfferRelaunch: Bool {
        guard screenRecording != .granted, let at = screenRecordingRequestedAt else { return false }
        return Date().timeIntervalSince(at) > 4
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("Launch at login change failed: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Relaunch

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait until this process has really exited (max ~10 s), then reopen.
        task.arguments = ["-c", "for i in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
