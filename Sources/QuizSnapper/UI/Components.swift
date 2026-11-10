import AppKit
import SwiftUI

// MARK: - Key caps

struct KeyCapsView: View {
    let combo: KeyCombo
    var small = false

    var body: some View {
        HStack(spacing: small ? 2 : 3) {
            ForEach(Array(combo.keyCaps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: small ? 10 : 11.5, weight: .medium, design: .rounded))
                    .frame(minWidth: small ? 14 : 18)
                    .padding(.horizontal, cap.count > 1 ? 4 : 2)
                    .padding(.vertical, small ? 1 : 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            }
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Shortcut recorder

/// Click → press a key combination → saved. ⌫ clears, ⎋ cancels.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    var isRefused = false
    var conflictsWith: (KeyCombo) -> String? = { _ in nil }

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?
    @State private var liveModifiers: NSEvent.ModifierFlags = []
    @State private var flagsMonitor: Any?
    @State private var recorderID = UUID()

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    if isRecording {
                        Image(systemName: "record.circle").foregroundStyle(.red)
                        Text(liveModifierString.isEmpty ? "Type shortcut…" : liveModifierString)
                            .foregroundStyle(.secondary)
                    } else if let combo {
                        KeyCapsView(combo: combo)
                    } else {
                        Text("Record shortcut").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
                .frame(minWidth: 130, minHeight: 22)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isRecording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : (isRefused ? Color.orange : Color.primary.opacity(0.12)),
                                      lineWidth: isRecording ? 1.5 : 0.5)
                )
            }
            .buttonStyle(.plain)
            .help(isRefused ? "macOS refused this shortcut — another app probably uses it." : "Click to record a new shortcut")

            if combo != nil && !isRecording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize()
                    .offset(y: 16)
            }
        }
        .onDisappear(perform: stop)
        // Only one recorder at a time, and never leave one armed when you switch away —
        // global shortcuts are paused while recording.
        .onReceive(NotificationCenter.default.publisher(for: .quizSnapperRecorderStarted)) { note in
            if (note.object as? UUID) != recorderID { stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private var liveModifierString: String {
        KeyCombo(keyCode: 0, modifiers: KeyCombo.carbonModifiers(from: liveModifiers)).modifierSymbols
    }

    private func toggle() { isRecording ? stop() : start() }

    private func start() {
        message = nil
        NotificationCenter.default.post(name: .quizSnapperRecorderStarted, object: recorderID)
        isRecording = true
        AppModel.shared?.beginShortcutRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            liveModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        monitor = nil
        flagsMonitor = nil
        liveModifiers = []
        if isRecording {
            isRecording = false
            AppModel.shared?.endShortcutRecording()
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.intersection([.command, .control, .option, .shift]).isEmpty
        if event.keyCode == 53 && plain { stop(); return } // esc
        if (event.keyCode == 51 || event.keyCode == 117) && plain { combo = nil; stop(); return } // delete
        let candidate = KeyCombo(event: event)
        if let error = candidate.validationError {
            message = error
            NSSound.beep()
            return
        }
        if let conflict = conflictsWith(candidate) {
            message = "Already used by “\(conflict)”"
            NSSound.beep()
            return
        }
        message = nil
        combo = candidate
        stop()
    }
}

// MARK: - Misc

struct StatusBadge: View {
    let granted: Bool
    var labelGranted = "Granted"
    var labelMissing = "Not granted"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            Text(granted ? labelGranted : labelMissing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(granted ? Color.green : Color.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill((granted ? Color.green : Color.orange).opacity(0.12)))
    }
}

struct IconTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(color.gradient)
            )
    }
}

extension Int {
    var compactTokens: String {
        if self >= 1000 { return String(format: "%.1fk", Double(self) / 1000) }
        return "\(self)"
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

extension Notification.Name {
    static let quizSnapperRecorderStarted = Notification.Name("QuizSnapperRecorderStarted")
}
