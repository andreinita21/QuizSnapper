import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private var store: SettingsStore!
    private var permissions: PermissionsManager!
    private var model: AppModel!
    private var statusItem: StatusItemController!
    private var hud: HUDController!
    private var disguise: DisguiseEngine!
    private let settingsNav = SettingsNavigation()

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("QuizSnapper \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") launching from \(Bundle.main.bundlePath)")
        NSApp.setActivationPolicy(.accessory)
        if UserDefaults.standard.string(forKey: "snapshotUI") == nil { terminateOtherInstances() }
        installMainMenu()
        UNUserNotificationCenter.current().delegate = self

        store = SettingsStore()
        permissions = PermissionsManager()
        model = AppModel(store: store, permissions: permissions)
        hud = HUDController(model: model, store: store)
        disguise = DisguiseEngine(store: store)
        statusItem = StatusItemController(model: model, disguise: disguise)

        statusItem.openSettings = { [weak self] pane in self?.showSettings(pane) }
        statusItem.openOnboarding = { [weak self] in self?.showOnboarding() }

        model.onBeforeCapture = { [weak self] in
            self?.statusItem.closePopover()
            self?.hud.hide()
        }
        model.onRunStarted = { [weak self] in
            guard let self else { return }
            if self.store.settings.hudEnabled || self.model.toast != nil { self.hud.show() }
            if self.model.run?.isActive != true { self.hud.scheduleAutoHide() }
        }
        model.onRunFinished = { [weak self] in
            guard let self else { return }
            if self.store.settings.hudEnabled { self.hud.show(); self.hud.scheduleAutoHide() }
        }
        model.onTogglePanel = { [weak self] in self?.statusItem.togglePopover() }
        model.onDismissAnswer = { [weak self] in
            self?.hud.hide()
            self?.statusItem.acknowledgeAnswer()
        }
        model.onNeedsPermissions = { [weak self] in self?.showOnboarding(step: .screenRecording) }

        // Keep the HUD anchored while the answer streams in.
        model.objectWillChange
            .throttle(for: .milliseconds(60), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // Nothing left to show (toast gone, overlay disabled) → don't leave an empty bubble.
                    let hasRun = self.model.run != nil && self.store.settings.hudEnabled
                    if self.model.toast == nil && !hasRun { self.hud.hide() } else { self.hud.reposition() }
                }
            }
            .store(in: &cancellables)

        // Flip Dock visibility live when the disguise is toggled while a window is open.
        store.$settings
            .map { $0.disguise.enabled && $0.disguise.hideFromDock }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] hide in
                guard let self, self.settingsWindow != nil || self.onboardingWindow != nil else { return }
                NSApp.setActivationPolicy(hide ? .accessory : .regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            .store(in: &cancellables)

        model.registerHotkeys()

        if DebugSnapshots.runIfRequested(model: model, store: store, permissions: permissions, disguise: disguise) {
            NSApp.terminate(nil)
            return
        }

        // `open QuizSnapper.app --args -openSettings profiles` jumps straight to a settings pane.
        if let raw = UserDefaults.standard.string(forKey: "openSettings"), let pane = SettingsPane(rawValue: raw) {
            showSettings(pane)
        } else if !store.settings.onboardingCompleted {
            showOnboarding()
        } else if !permissions.allRequiredGranted && !store.settings.disguise.enabled {
            // While disguised, don't pop a "QuizSnapper" window at login — the panel shows a Fix banner instead.
            showOnboarding(step: .screenRecording)
        }
        Log.write("Ready. Screen recording: \(permissions.screenRecording)")
    }

    /// Two copies (e.g. an old build somewhere else) would fight over hotkeys and the menu bar. Newest wins.
    private func terminateOtherInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        for app in others {
            Log.write("Another QuizSnapper is running (pid \(app.processIdentifier), \(app.bundleURL?.path ?? "?")) — closing it")
            app.terminate()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(.general)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.saveNow()
    }

    // MARK: Windows

    func showSettings(_ pane: SettingsPane) {
        settingsNav.pane = pane
        if settingsWindow == nil {
            let view = SettingsView(model: model, store: store, permissions: permissions, disguise: disguise, nav: settingsNav,
                                    runOnboarding: { [weak self] in self?.showOnboarding(step: .welcome) })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "QuizSnapper Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 940, height: 660))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("QuizSnapperSettings")
            settingsWindow = window
        }
        present(settingsWindow)
    }

    func showOnboarding(step: OnboardingStep? = nil) {
        if let step { store.settings.onboardingStep = step.rawValue }
        if onboardingWindow == nil {
            let view = OnboardingView(model: model, store: store, permissions: permissions,
                                      finish: { [weak self] in self?.onboardingWindow?.close() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to QuizSnapper"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            onboardingWindow = window
        }
        present(onboardingWindow)
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        let d = store.settings.disguise
        if !(d.enabled && d.hideFromDock) {
            NSApp.setActivationPolicy(.regular) // show in Dock / ⌘-Tab while a window is open
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == onboardingWindow {
            onboardingWindow = nil
            store.saveNow()
        }
        if window == settingsWindow { settingsWindow = nil }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.settingsWindow == nil && self.onboardingWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    // MARK: Notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: Menu (needed so ⌘C / ⌘V / ⌘A work in text fields)

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide QuizSnapper", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit QuizSnapper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    @objc private func openSettingsFromMenu() { showSettings(.general) }
}
