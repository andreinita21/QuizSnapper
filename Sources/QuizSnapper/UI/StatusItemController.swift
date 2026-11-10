import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?

    var openSettings: (SettingsPane) -> Void = { _ in }
    var openOnboarding: () -> Void = {}

    let disguise: DisguiseEngine

    init(model: AppModel, disguise: DisguiseEngine) {
        self.model = model
        self.disguise = disguise
        super.init()
        statusItem.autosaveName = "QuizSnapperStatusItem"

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        model.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        disguise.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    private var disguiseSettings: DisguiseSettings { model.settings.disguise }

    // MARK: Appearance

    func refresh() {
        guard let button = statusItem.button else { return }
        if disguiseSettings.enabled {
            applyDisguise(to: button)
            return
        }
        endFlash()   // the plain icon shows the answer anyway
        button.setAccessibilityLabel("QuizSnapper")
        button.imagePosition = .imageLeading
        var symbol = "text.viewfinder"
        var title = ""

        if model.isCapturing {
            symbol = "camera.aperture"
        } else if let run = model.run, run.isActive {
            symbol = "ellipsis.circle"
        } else if let run = model.run, run.errorMessage != nil {
            symbol = "exclamationmark.triangle"
        } else if let run = model.run, run.phase == .done {
            switch run.menuBarDisplay {
            case .letter:
                switch run.shape {
                case .letters(let l):
                    // Keep the menu bar tidy for multi-question answers ("1:B 2:A,D 3:C …").
                    title = Self.shortLetters(l)
                    symbol = ""
                case .fillIn:
                    // Too long for the menu bar — it went to the clipboard instead.
                    symbol = model.settings.autoCopyFillInAnswers ? "doc.on.clipboard" : "checkmark.circle"
                case .none:
                    symbol = "checkmark.circle"
                }
            case .firstLine:
                title = AnswerParser.firstLine(of: run.answer); symbol = ""
            case .iconOnly:
                symbol = "checkmark.circle"
            }
        }
        if !model.stack.isEmpty {
            title = title.isEmpty ? "\(model.stack.count)" : "\(title) · \(model.stack.count)"
            if symbol.isEmpty || symbol == "text.viewfinder" { symbol = "square.stack.3d.up" }
        }

        if symbol.isEmpty {
            button.image = nil
        } else {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "QuizSnapper")
            image?.isTemplate = true
            button.image = image
        }
        button.title = title.isEmpty ? "" : (symbol.isEmpty ? title : " \(title)")
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    }

    // MARK: Disguise state

    /// The run whose answer the user has already seen (opened the panel / hid the overlay).
    private var acknowledgedRunID: UUID?
    private var readyTimeoutWork: DispatchWorkItem?

    func acknowledgeAnswer() {
        acknowledgedRunID = model.run?.id
        endFlash()
        refresh()
    }

    // MARK: Answer flash

    /// When an answer arrives, the disguised icon is replaced for a couple of seconds by the
    /// bare answer — the letters to click, or a clipboard glyph when the answer is text that
    /// was copied instead. Then the disguise comes straight back. Once per run.
    private var flashedRunID: UUID?
    private var flashingRunID: UUID?
    private var flashWork: DispatchWorkItem?

    static func shortLetters(_ l: String) -> String { l.count > 24 ? String(l.prefix(23)) + "…" : l }

    private func flashLook(for run: RunState) -> DisguiseEngine.Appearance? {
        switch run.shape {
        case .letters(let l):
            let text = Self.shortLetters(l)
            return DisguiseEngine.Appearance(image: nil, title: text, accessibilityLabel: text)
        case .fillIn(let values):
            guard model.settings.autoCopyFillInAnswers else { return nil }
            return DisguiseEngine.Appearance(image: DisguiseEngine.symbol("doc.on.clipboard"), title: "",
                                             accessibilityLabel: "\(values.count) answers copied")
        case .none:
            return nil
        }
    }

    private func startFlashIfNeeded(for run: RunState) {
        let seconds = model.settings.answerFlashSeconds
        guard seconds > 0, run.id != flashedRunID, flashLook(for: run) != nil else { return }
        flashedRunID = run.id
        flashingRunID = run.id
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flashingRunID = nil
            self?.flashWork = nil
            self?.refresh()
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func endFlash() {
        flashWork?.cancel()
        flashWork = nil
        flashingRunID = nil
    }

    private func applyFlash(_ look: DisguiseEngine.Appearance, to button: NSStatusBarButton) {
        button.image = look.image
        button.title = look.title
        button.font = look.title.isEmpty ? NSFont.menuBarFont(ofSize: 0)
                                         : NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        button.imagePosition = look.title.isEmpty ? .imageOnly : (look.image == nil ? .noImage : .imageLeading)
        button.setAccessibilityLabel(look.accessibilityLabel)
        button.toolTip = nil
    }

    private var indicatorState: DisguiseEngine.IndicatorState {
        if model.isCapturing { return .working }
        guard let run = model.run else { return .idle }
        // Answer finished while the panel was open → it has been seen.
        if popover.isShown && run.phase == .done { acknowledgedRunID = run.id }
        if run.isActive { return .working }
        guard run.phase == .done, run.id != acknowledgedRunID else { return .idle }
        let timeout = disguiseSettings.readyTimeoutSeconds
        if timeout > 0, let finished = run.finishedAt, Date().timeIntervalSince(finished) >= timeout { return .idle }
        return .ready
    }

    private func applyDisguise(to button: NSStatusBarButton) {
        let state = indicatorState
        if state == .ready, let run = model.run { startFlashIfNeeded(for: run) }
        if let run = model.run, run.id == flashingRunID, let look = flashLook(for: run) {
            applyFlash(look, to: button)
            return
        }
        if state == .ready, disguiseSettings.readyTimeoutSeconds > 0, readyTimeoutWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.readyTimeoutWork = nil; self?.refresh() }
            readyTimeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + disguiseSettings.readyTimeoutSeconds + 0.1, execute: work)
        }
        let look = disguise.appearance(state: state)
        button.image = look.image
        var title = look.title
        // Optionally leak the answer next to the disguise (off by default).
        if disguiseSettings.showLetters, state == .ready, let l = model.run?.letters {
            title = title.isEmpty ? l : "\(title) \(l)"
        }
        button.title = title
        button.font = NSFont.menuBarFont(ofSize: 0)
        button.imagePosition = title.isEmpty ? .imageOnly : (look.imageTrailing ? .imageTrailing : .imageLeading)
        button.setAccessibilityLabel(look.accessibilityLabel)
        button.toolTip = nil
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
        // Union with the live keyboard state: some synthesized / accessibility clicks carry no modifier flags.
        let flags = (event?.modifierFlags ?? []).union(NSEvent.modifierFlags)
            .intersection([.command, .option, .control, .shift])

        let d = disguiseSettings
        guard d.enabled else {
            if isRight || flags.contains(.control) { showMenu() } else { togglePopover() }
            return
        }

        let gesture = matches(d.revealGesture, flags: flags, isRight: isRight)
        if popover.isShown { closePopover(); return }
        if d.requireRevealGesture {
            gesture ? showPopover() : showFakeMenu()
        } else {
            gesture ? showFakeMenu() : showPopover()
        }
    }

    private func matches(_ gesture: RevealGesture, flags: NSEvent.ModifierFlags, isRight: Bool) -> Bool {
        switch gesture {
        case .optionClick: return flags == [.option] && !isRight
        case .commandClick: return flags == [.command] && !isRight
        case .controlClick: return flags == [.control]
        case .shiftClick: return flags == [.shift] && !isRight
        case .rightClick: return isRight && flags.isEmpty
        case .optionCommandClick: return flags == [.option, .command] && !isRight
        }
    }

    private func showFakeMenu() {
        guard let menu = disguise.makeMenu(disguiseSettings.activeMenu) else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func togglePopover() {
        popover.isShown ? closePopover() : showPopover()
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        let view = PanelView(model: model, store: model.store, permissions: model.permissions,
                             openSettings: { [weak self] pane in self?.closePopover(); self?.openSettings(pane) },
                             openOnboarding: { [weak self] in self?.closePopover(); self?.openOnboarding() },
                             close: { [weak self] in self?.closePopover() })
        if model.run?.phase == .done { acknowledgedRunID = model.run?.id }
        popover.contentViewController = NSHostingController(rootView: view)
        FocusKeeper.remember()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.sharingType = .none
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        // Let the window fully go away, then hand focus back (unless Settings/capture took over).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { FocusKeeper.restore() }
    }

    func closePopover() {
        popover.performClose(nil)
    }

    private func showMenu() {
        let menu = NSMenu()
        func item(_ title: String, _ action: ShortcutAction) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = action.rawValue
            i.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            return i
        }
        menu.addItem(item("Snap & Ask", .snapAndAsk))
        menu.addItem(item("Region & Ask", .regionAndAsk))
        menu.addItem(.separator())
        menu.addItem(item("Add Screen to Stack", .addScreen))
        menu.addItem(item("Add Region to Stack", .addRegion))
        if !model.stack.isEmpty { menu.addItem(item("Send Stack (\(model.stack.count))", .sendStack)) }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit QuizSnapper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = ShortcutAction(rawValue: raw) else { return }
        model.perform(action)
    }

    @objc private func openSettingsMenu() { openSettings(.general) }
}
