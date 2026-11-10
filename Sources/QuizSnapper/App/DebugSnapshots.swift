import AppKit
import SwiftUI

/// `QuizSnapper -snapshotUI <dir>` renders the panel, HUD and fake menus to PNGs and quits.
/// These windows are hidden from screen capture on purpose, so this is how they get checked visually.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(model: AppModel, store: SettingsStore, permissions: PermissionsManager,
                               disguise: DisguiseEngine) -> Bool {
        guard let dir = UserDefaults.standard.string(forKey: "snapshotUI") else { return false }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let shot = CapturedShot(image: sampleImage(), isRegion: false)
        var run = RunState(profileName: "Quiz — quick answer", profileIcon: "checkmark.circle.fill", providerName: "Claude",
                           model: "claude-opus-5-5", menuBarDisplay: .letter, imageCount: 2)
        run.phase = .done
        run.answer = "B\nPhotosynthesis converts light energy into chemical energy stored in glucose."
        run.reasoning = "The question asks about energy conversion; option B matches."
        run.finishedAt = run.startedAt.addingTimeInterval(3.4)
        run.outputTokens = 812
        model.debugSetState(run: run, stack: [shot, CapturedShot(image: sampleImage(), isRegion: true)])

        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            render(PanelView(model: model, store: store, permissions: permissions,
                             openSettings: { _ in }, openOnboarding: {}, close: {}), scheme, out, "panel-\(suffix)")
            render(HUDView(model: model, store: store, onClose: {}), scheme, out, "hud-\(suffix)")
        }

        // Fill-in-the-blank answer: values on the clipboard instead of letters in the menu bar.
        var fill = run
        fill.answer = "FILL: chmod 755; /etc/passwd; 3\nFirst sets the permissions; the others name the file and the count."
        model.debugSetState(run: fill, stack: [])
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            render(PanelView(model: model, store: store, permissions: permissions,
                             openSettings: { _ in }, openOnboarding: {}, close: {}), scheme, out, "panel-fillin-\(suffix)")
            render(HUDView(model: model, store: store, onClose: {}), scheme, out, "hud-fillin-\(suffix)")
        }

        var failed = run
        failed.phase = .failed("HTTP 401: invalid x-api-key")
        failed.answer = "B\nPartial answer before the connection dro"
        model.debugSetState(run: failed, stack: [])
        render(PanelView(model: model, store: store, permissions: permissions,
                         openSettings: { _ in }, openOnboarding: {}, close: {}), .dark, out, "panel-error")

        var active = run
        active.phase = .waiting
        active.answer = ""
        active.finishedAt = nil
        model.debugSetState(run: active, stack: [])
        render(HUDView(model: model, store: store, onClose: {}), .dark, out, "hud-working")

        for kind in FakeMenuKind.allCases where kind != .none {
            guard let menu = disguise.makeMenu(kind) else { continue }
            var y = 0
            for (i, item) in menu.items.enumerated() {
                if let view = item.view {
                    write(view, out.appendingPathComponent("menu-\(kind.rawValue)-\(i).png"))
                    y += 1
                }
            }
        }
        Log.write("UI snapshots written to \(out.path)")
        return true
    }

    private static func render<V: View>(_ view: V, _ scheme: ColorScheme, _ dir: URL, _ name: String) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        write(host, dir.appendingPathComponent("\(name).png"))
    }

    private static func write(_ view: NSView, _ url: URL) {
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func sampleImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        for i in 0..<4 { ctx.fill(CGRect(x: 20, y: 30 + i * 40, width: 200 - i * 30, height: 14)) }
        return ctx.makeImage()!
    }
}
