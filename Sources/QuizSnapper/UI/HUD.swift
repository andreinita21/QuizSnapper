import AppKit
import SwiftUI

/// Small floating answer overlay. Non-activating (doesn't steal focus) and excluded from
/// screen capture/sharing, so it never shows up in your own screenshots or screen shares.
@MainActor
final class HUDController {
    private let model: AppModel
    private let store: SettingsStore
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    init(model: AppModel, store: SettingsStore) {
        self.model = model
        self.store = store
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        let host = NSHostingView(rootView: HUDView(model: model, store: store, onClose: { [weak self] in self?.hide() }))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }

    /// Where the bubble is pinned: chosen once when it appears, so it doesn't chase the mouse
    /// across displays while the answer streams in.
    private var anchor: (screen: NSRect, point: NSPoint, growsDown: Bool, centered: Bool)?
    private var lastFrame: NSRect?
    private var userMoved = false

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.alphaValue = store.settings.hudOpacity
        hideWorkItem?.cancel()
        if !panel.isVisible {
            anchor = nil
            userMoved = false
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        position(panel)
        panel.orderFrontRegardless()
    }

    /// Called whenever content changes size (streaming); keeps the anchored edge fixed.
    func reposition() {
        guard let panel, panel.isVisible else { return }
        position(panel)
    }

    func scheduleAutoHide() {
        hideWorkItem?.cancel()
        let seconds = store.settings.hudAutoHideSeconds
        guard seconds > 0 else { return }
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func hide() {
        hideWorkItem?.cancel()
        panel?.orderOut(nil)
        anchor = nil
        userMoved = false
    }

    private func makeAnchor(size: NSSize) -> (screen: NSRect, point: NSPoint, growsDown: Bool, centered: Bool)? {
        guard let screen = ScreenCapturer.screenUnderMouse else { return nil }
        let vf = screen.visibleFrame
        let m: CGFloat = 16
        switch store.settings.hudPosition {
        case .topRight: return (vf, NSPoint(x: vf.maxX - size.width - m, y: vf.maxY - m), true, false)
        case .topLeft: return (vf, NSPoint(x: vf.minX + m, y: vf.maxY - m), true, false)
        case .bottomRight: return (vf, NSPoint(x: vf.maxX - size.width - m, y: vf.minY + m), false, false)
        case .bottomLeft: return (vf, NSPoint(x: vf.minX + m, y: vf.minY + m), false, false)
        case .topCenter: return (vf, NSPoint(x: vf.midX, y: vf.maxY - m), true, true)
        case .nearCursor:
            let mouse = NSEvent.mouseLocation
            return (vf, NSPoint(x: mouse.x + 18, y: mouse.y - 18), true, false)
        }
    }

    private func position(_ panel: NSPanel) {
        let size = panel.contentView?.fittingSize ?? NSSize(width: 360, height: 80)
        // A drag by the user wins: from then on only resize, keeping the top edge where they put it.
        if let last = lastFrame, panel.isVisible,
           abs(panel.frame.origin.x - last.origin.x) > 1 || abs(panel.frame.maxY - last.maxY) > 1 {
            userMoved = true
        }
        var frame: NSRect
        if userMoved {
            frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
        } else {
            if anchor == nil { anchor = makeAnchor(size: size) }
            guard let a = anchor else { return }
            let x = a.centered ? a.point.x - size.width / 2 : a.point.x
            let y = a.growsDown ? a.point.y - size.height : a.point.y
            frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            // Keep it on the display it started on.
            let m: CGFloat = 8
            frame.origin.x = min(max(frame.minX, a.screen.minX + m), a.screen.maxX - size.width - m)
            frame.origin.y = min(max(frame.minY, a.screen.minY + m), a.screen.maxY - size.height - m)
        }
        lastFrame = frame
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

struct HUDView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let toast = model.toast {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                    Text(toast).font(.system(size: 12, weight: .medium))
                }
            }
            if let run = model.run, store.settings.hudEnabled {
                runContent(run)
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .onTapGesture(count: 2) {
            if let answer = model.run?.answer, !answer.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
                model.showToast("Answer copied")
            }
        }
        .contextMenu {
            Button("Copy answer") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.run?.answer ?? "", forType: .string)
            }
            Button("Hide") { onClose() }
        }
    }

    @ViewBuilder private func runContent(_ run: RunState) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill((run.errorMessage != nil ? Color.red : Color.accentColor).gradient)
                if run.isActive && run.answer.isEmpty {
                    ProgressView().controlSize(.small).tint(.white)
                } else if run.errorMessage != nil {
                    Image(systemName: "exclamationmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                } else if let l = run.letters, l.count <= 7 {
                    Text(l.replacingOccurrences(of: ",", with: " "))
                        .font(.system(size: l.count > 3 ? 12 : 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                        .padding(2)
                } else if run.shape.isFillIn {
                    Image(systemName: "doc.on.clipboard.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                } else {
                    Image(systemName: run.profileIcon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(run.profileName).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
                if let error = run.errorMessage {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red).lineLimit(4)
                } else if run.phase == .cancelled && run.answer.isEmpty {
                    Text("Stopped").font(.system(size: 12)).foregroundStyle(.secondary)
                } else if run.answer.isEmpty {
                    Text(run.reasoning.isEmpty ? "Thinking…" : "Reasoning…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    if let fill = run.shape.clipboardText {
                        Text(fill)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if store.settings.autoCopyFillInAnswers {
                            Text("Copied — paste with ⌘V")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    if store.settings.hudShowExplanation {
                        Text(markdown(run.hasHeadline ? (run.explanation.isEmpty ? run.answer : run.explanation) : run.answer))
                            .font(.system(size: 12))
                            .lineLimit(12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
