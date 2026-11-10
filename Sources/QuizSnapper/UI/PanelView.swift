import SwiftUI

/// The menu bar popover.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var permissions: PermissionsManager
    var openSettings: (SettingsPane) -> Void
    var openOnboarding: () -> Void
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    if !permissions.screenRecording.isGranted { permissionBanner }
                    if let run = model.run { AnswerCard(run: run, model: model, store: store) }
                    stackSection
                    quickActions
                }
                .padding(14)
            }
            .frame(maxHeight: 520)
            Divider()
            footer
        }
        .frame(width: 400)
        .onAppear { permissions.refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("QuizSnapper").font(.system(size: 13, weight: .semibold))
                if let p = store.activeProfile, let provider = store.provider(for: p) {
                    Text("\(provider.name) · \(p.model.isEmpty ? "no model" : p.model)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            profileMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var profileMenu: some View {
        Menu {
            ForEach(store.settings.profiles) { profile in
                Button {
                    store.setActiveProfile(profile.id)
                } label: {
                    if profile.id == store.settings.activeProfileID {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            Divider()
            Button("Edit profiles…") { openSettings(.profiles) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: store.activeProfile?.icon ?? "bolt.fill")
                Text(store.activeProfile?.name ?? "Profile").lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    // MARK: Permission banner

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Recording is off").font(.system(size: 12, weight: .semibold))
                Text("QuizSnapper can't take screenshots until you allow it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Fix") { openOnboarding() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.1)))
    }

    // MARK: Stack

    private var stackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Screenshot stack", systemImage: "square.stack.3d.up")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(model.stack.count)/\(store.settings.maxStackSize)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.stack.isEmpty {
                    Button("Clear") { model.clearStack() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }

            if model.stack.isEmpty {
                Text("Collect several screenshots (a long question, multiple pages…) and send them together in one request.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.stack.enumerated()), id: \.element.id) { idx, shot in
                            StackThumb(shot: shot, index: idx + 1,
                                       onRemove: { model.removeShot(shot.id) },
                                       onLeft: idx > 0 ? { model.moveShot(shot.id, by: -1) } : nil,
                                       onRight: idx < model.stack.count - 1 ? { model.moveShot(shot.id, by: 1) } : nil)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack(spacing: 8) {
                actionButton(.addScreen, title: "Add screen") { close(); model.addToStack(region: false) }
                actionButton(.addRegion, title: "Add region") { close(); model.addToStack(region: true) }
                Spacer()
                Button {
                    close()
                    model.sendStack()
                } label: {
                    Label("Ask (\(model.stack.count))", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.stack.isEmpty)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func actionButton(_ action: ShortcutAction, title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: action.symbol)
        }
        .controlSize(.small)
        .help(store.settings.shortcut(action).map { "\(action.title) — \($0.displayString)" } ?? action.title)
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            QuickActionTile(title: "Snap & ask", symbol: "camera.viewfinder",
                            combo: store.settings.shortcut(.snapAndAsk)) {
                close(); model.snapAndAsk()
            }
            QuickActionTile(title: "Region & ask", symbol: "crop",
                            combo: store.settings.shortcut(.regionAndAsk)) {
                close(); model.regionAndAsk()
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button { openSettings(.history) } label: { Label("History", systemImage: "clock.arrow.circlepath") }
            Button { openSettings(.general) } label: { Label("Settings", systemImage: "gearshape") }
            Spacer()
            Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
        }
        .buttonStyle(.plain)
        .labelStyle(.titleAndIcon)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Answer card

struct AnswerCard: View {
    let run: RunState
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @State private var showReasoning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 4) {
                    statusLine
                    content
                }
                Spacer(minLength: 0)
            }

            if !run.reasoning.isEmpty {
                DisclosureGroup(isExpanded: $showReasoning) {
                    ScrollView {
                        Text(run.reasoning)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                } label: {
                    Label("Reasoning", systemImage: "brain").font(.system(size: 11, weight: .medium))
                }
            }

            HStack(spacing: 8) {
                Text(meta).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                if run.isActive {
                    Button("Stop") { model.cancel() }.controlSize(.small)
                } else {
                    if !run.answer.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(run.answer, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy answer")
                    }
                    Menu {
                        ForEach(store.settings.profiles) { p in
                            Button(p.name) { model.retry(profileID: p.id) }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    } primaryAction: {
                        model.retry()
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Ask again (click) or ask again with another profile (hold)")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(run.errorMessage != nil ? Color.red.opacity(0.08) : Color.accentColor.opacity(0.07))
        )
    }

    @ViewBuilder private var badge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(badgeColor.gradient)
                .frame(width: 48, height: 48)
            if run.isActive && run.answer.isEmpty {
                ProgressView().controlSize(.small).tint(.white)
            } else if run.errorMessage != nil {
                Image(systemName: "exclamationmark").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
            } else if let letters = run.letters, letters.count <= 7 {
                Text(letters.replacingOccurrences(of: ",", with: " "))
                    .font(.system(size: letters.count > 3 ? 14 : 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .padding(4)
            } else if run.shape.isFillIn {
                Image(systemName: "doc.on.clipboard.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            } else {
                Image(systemName: run.profileIcon).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 48, height: 48)
    }

    private var badgeColor: Color {
        if run.errorMessage != nil { return .red }
        if run.phase == .cancelled { return .gray }
        return .accentColor
    }

    @ViewBuilder private var statusLine: some View {
        switch run.phase {
        case .preparing: Text("Preparing \(run.imageCount) image\(run.imageCount == 1 ? "" : "s")…").font(.caption).foregroundStyle(.secondary)
        case .waiting: Text(run.reasoning.isEmpty ? "Thinking…" : "Reasoning…").font(.caption).foregroundStyle(.secondary)
        case .cancelled: Text("Stopped").font(.caption).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        if let error = run.errorMessage {
            if !run.answer.isEmpty {
                // Keep whatever arrived before the connection dropped.
                Text(markdown(run.answer))
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if !run.answer.isEmpty {
            if let fill = run.shape.clipboardText {
                // Fill-in-the-blank: the values to type, ready to paste.
                Text(fill)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Label(store.settings.autoCopyFillInAnswers ? "Copied to the clipboard" : "Auto-copy is off in Settings",
                          systemImage: "doc.on.clipboard")
                        .foregroundStyle(.secondary)
                    Button("Copy values") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fill, forType: .string)
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption2)
                .padding(.bottom, 2)
            }
            // The badge already shows the letter — don't repeat it as the first line.
            Text(markdown(run.hasHeadline && !run.explanation.isEmpty ? run.explanation : run.answer))
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if run.wasTruncated {
                Label("Cut off by the max-tokens limit", systemImage: "scissors")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private var meta: String {
        var parts = [run.providerName, run.model]
        parts.append("\(run.imageCount) img")
        parts.append(String(format: "%.1fs", run.duration))
        if let out = run.outputTokens { parts.append("\(out.compactTokens) out") }
        return parts.joined(separator: " · ")
    }
}

func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}

// MARK: - Small pieces

struct StackThumb: View {
    let shot: CapturedShot
    let index: Int
    var onRemove: () -> Void
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: shot.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 92, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 3) {
                        Text("\(index)")
                        if shot.isRegion { Image(systemName: "crop") }
                    }
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(4)
                }
                .overlay(alignment: .bottomTrailing) {
                    if hovering {
                        HStack(spacing: 2) {
                            if let onLeft { Button(action: onLeft) { Image(systemName: "chevron.left") } }
                            if let onRight { Button(action: onRight) { Image(systemName: "chevron.right") } }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(4)
                    }
                }
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.7))
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
            }
        }
        .onHover { hovering = $0 }
    }
}

struct QuickActionTile: View {
    let title: String
    let symbol: String
    let combo: KeyCombo?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
                if let combo { KeyCapsView(combo: combo, small: true) } else { Text(" ").font(.system(size: 10)) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovering ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
