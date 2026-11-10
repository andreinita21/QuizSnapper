import AppKit

/// Freezes the screen under the cursor and lets the user drag a rectangle (like ⌘⇧4).
/// Enter = whole screen, Esc = cancel.
@MainActor
final class RegionSelector {
    private static var active: RegionSelector?

    private var window: SelectionWindow?
    private var continuation: CheckedContinuation<CGImage?, Never>?

    static func select() async throws -> CGImage? {
        guard active == nil else { return nil }
        guard let screen = ScreenCapturer.screenUnderMouse else { throw CaptureError.noDisplay }
        let full = try await ScreenCapturer.captureScreen(screen)
        let selector = RegionSelector()
        active = selector
        defer { active = nil }
        return await selector.run(on: screen, image: full)
    }

    private func run(on screen: NSScreen, image: CGImage) async -> CGImage? {
        await withCheckedContinuation { cont in
            continuation = cont
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image)
            view.onFinish = { [weak self] result in self?.finish(result) }
            let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.sharingType = .none
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            self.window = window
            FocusKeeper.remember()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            NSCursor.crosshair.push()
        }
    }

    private func finish(_ result: CGImage?) {
        NSCursor.pop()
        window?.orderOut(nil)
        window = nil
        continuation?.resume(returning: result)
        continuation = nil
        FocusKeeper.restore()
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionView: NSView {
    let image: CGImage
    let nsImage: NSImage
    var onFinish: ((CGImage?) -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero
    private var finished = false

    init(frame: NSRect, image: CGImage) {
        self.image = image
        self.nsImage = NSImage(cgImage: image, size: frame.size)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        nsImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        let dim = NSBezierPath(rect: bounds)
        if currentRect.width > 0, currentRect.height > 0 {
            dim.append(NSBezierPath(rect: currentRect))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()

        if currentRect.width > 0, currentRect.height > 0 {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: currentRect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            drawSizeLabel()
        } else {
            drawHint()
        }
    }

    private func pill(_ text: String, at point: NSPoint, centered: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        var origin = point
        if centered { origin.x -= (size.width + 24) / 2 }
        let rect = NSRect(x: origin.x, y: origin.y, width: size.width + 24, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        str.draw(at: NSPoint(x: rect.minX + 12, y: rect.minY + 6))
    }

    private func drawHint() {
        pill("Drag to select  ·  ↩ whole screen  ·  esc cancel", at: NSPoint(x: bounds.midX, y: 40), centered: true)
    }

    private func drawSizeLabel() {
        let scale = CGFloat(image.width) / bounds.width
        let text = "\(Int(currentRect.width * scale)) × \(Int(currentRect.height * scale))"
        var y = currentRect.maxY + 8
        if y + 30 > bounds.maxY { y = currentRect.minY - 34 }
        pill(text, at: NSPoint(x: currentRect.minX, y: max(y, 4)), centered: false)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                             width: abs(p.x - start.x), height: abs(p.y - start.y)).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard currentRect.width > 6, currentRect.height > 6 else {
            currentRect = .zero
            needsDisplay = true
            return
        }
        complete(with: crop(currentRect))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: complete(with: nil) // esc
        case 36, 76: complete(with: currentRect.width > 6 ? crop(currentRect) : image) // return / enter
        default: super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) { complete(with: nil) }

    private func complete(with result: CGImage?) {
        guard !finished else { return }
        finished = true
        onFinish?(result)
    }

    private func crop(_ rect: NSRect) -> CGImage? {
        let sx = CGFloat(image.width) / bounds.width
        let sy = CGFloat(image.height) / bounds.height
        let pixelRect = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy).integral
        return image.cropping(to: pixelRect)
    }
}
