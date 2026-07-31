// AICodingModule.swift
// Claude Code sessions in the notch, with Allow/Deny when the CLI is blocked.
//
// The audit scored this 🟡→✅: Mira already had more agent machinery than
// MacNotch (ClaudeCodeBridge, CodexService, the HUD, bidirectional MCP), and
// was missing exactly one thing — the affordance that answers a permission
// prompt without switching to the terminal. That gap is what this module and
// AICodingBridgeService close.
//
// The panel is deliberately dull when nothing needs you. A waiting session is
// the only state that gets color, because a permission prompt you scroll past
// is a permission prompt you approve without reading.

import SwiftUI
import Combine

@MainActor
final class AICodingModule: NotchModule, ObservableObject {

    let id    = "aicoding"
    let title = "AI Coding"
    let icon  = "chevron.left.forwardslash.chevron.right"

    let heightLevel: NotchHeightLevel = .standard
    let allowsTallMode = true

    private let bridge    = AICodingBridgeService.shared
    private let installer = AICodingHookInstaller.shared
    private var cancellables = Set<AnyCancellable>()

    /// Session the user drilled into.
    @Published private(set) var detailSessionID: String?

    var detailTitle: String? { detailSessionID == nil ? nil : "AI Coding" }
    func popDetail() { detailSessionID = nil }

    func show(_ session: AICodingSession) { detailSessionID = session.id }

    var subtitle: NotchHeaderSubtitle? {
        if let id = detailSessionID,
           let session = bridge.sessions.first(where: { $0.id == id }) {
            return NotchHeaderSubtitle(text: session.folderName, isPill: true)
        }
        let waiting = bridge.sessions.filter { $0.status == .waiting }.count
        if waiting > 0 {
            return NotchHeaderSubtitle(text: waiting == 1 ? "1 waiting" : "\(waiting) waiting",
                                       isPill: true)
        }
        let live = bridge.sessions.filter { $0.status != .ended }.count
        return NotchHeaderSubtitle(text: live == 1 ? "1 session" : "\(live) sessions")
    }

    init() {
        for p in [bridge.objectWillChange, installer.objectWillChange] {
            p.sink { [weak self] _ in self?.objectWillChange.send() }
             .store(in: &cancellables)
        }
    }

    func didAppear() {
        installer.refresh()
        // Safe to call repeatedly; it no-ops once the listener is up. Opening
        // the module is also the moment a user who just installed the hook
        // expects it to start working.
        if installer.isInstalled { bridge.start() }
    }

    func didDisappear() { detailSessionID = nil }

    func makeContent() -> AnyView {
        AnyView(AICodingView(module: self, bridge: bridge, installer: installer))
    }
}

// MARK: - View

private struct AICodingView: View {

    @ObservedObject var module: AICodingModule
    @ObservedObject var bridge: AICodingBridgeService
    @ObservedObject var installer: AICodingHookInstaller
    @ObservedObject private var accentSvc = AccentColorService.shared

    private var accent: Color { accentSvc.color }

    var body: some View {
        Group {
            if let id = module.detailSessionID,
               let session = bridge.sessions.first(where: { $0.id == id }) {
                detail(session)
            } else if !installer.isInstalled {
                setup
            } else {
                sessionList
            }
        }
        .padding(.top, NotchModuleShellView.headerHeight + 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(Color.black)
    }

    // MARK: Setup

    /// Shown until the CLI hook exists. Says what it will change, because it
    /// edits a file the user owns and may well have written by hand.
    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Answer Claude Code from the notch")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))

            Text("Mira installs a hook script and adds it to ~/.claude/settings.json. "
                 + "When Claude Code asks to run a command or write a file, you can allow "
                 + "or deny it here instead of switching to the terminal.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Text("Your other hooks are left alone, and nothing is sent anywhere — the "
                 + "hook talks to Mira over a local socket only you can read.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    installer.install()
                    if installer.isInstalled { bridge.start() }
                } label: {
                    Text("Connect Claude Code")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)

                if let error = installer.lastError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.45))
                        .lineLimit(2)
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
    }

    // MARK: List

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 5) {
            if bridge.sessions.isEmpty {
                Text(bridge.isListening
                     ? "No sessions yet. Start Claude Code in a terminal and it will appear here."
                     : "Not listening — \(bridge.lastError ?? "the socket could not be opened").")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    // Anything waiting on a human sorts to the top regardless of
                    // recency — it is the only row with a deadline.
                    ForEach(sortedSessions) { session in
                        SessionRow(session: session,
                                   accent: accent,
                                   onOpen: { module.show(session) },
                                   onAllow: { bridge.respond(sessionID: session.id, approve: true) },
                                   onDeny:  { bridge.respond(sessionID: session.id, approve: false) })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
    }

    private var sortedSessions: [AICodingSession] {
        bridge.sessions.sorted { a, b in
            if (a.status == .waiting) != (b.status == .waiting) { return a.status == .waiting }
            return a.lastSeen > b.lastSeen
        }
    }

    // MARK: Detail

    private func detail(_ session: AICodingSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let pending = session.pending {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            ToolChip(name: pending.toolName, accent: accent, emphasized: true)
                            Text("is waiting for you")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.6))
                            Spacer(minLength: 0)
                            CountdownText(deadline: pending.deadline)
                        }
                        if !pending.fullInput.isEmpty {
                            Text(pending.fullInput)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.05)))
                        }
                        HStack(spacing: 8) {
                            DecisionButton(title: "Allow", isPrimary: true, accent: accent) {
                                AICodingBridgeService.shared.respond(sessionID: session.id, approve: true)
                                module.popDetail()
                            }
                            DecisionButton(title: "Deny", isPrimary: false, accent: accent) {
                                AICodingBridgeService.shared.respond(sessionID: session.id, approve: false)
                                module.popDetail()
                            }
                        }
                    }
                }

                Text("RECENT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.32))

                ForEach(session.events.reversed()) { event in
                    HStack(alignment: .top, spacing: 6) {
                        ToolChip(name: event.toolName, accent: accent, emphasized: false)
                        Text(event.detail ?? "—")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }

                if session.events.isEmpty {
                    Text("No tool calls yet.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Row

private struct SessionRow: View {

    let session: AICodingSession
    let accent: Color
    let onOpen: () -> Void
    let onAllow: () -> Void
    let onDeny: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: onOpen) {
                HStack(spacing: 7) {
                    Image(systemName: session.source.icon)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 14)

                    Text(session.folderName.isEmpty ? session.source.display : session.folderName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)

                    StatusDot(status: session.status, accent: accent)

                    Text(statusText)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if let last = session.events.last {
                        Text(last.toolName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            .buttonStyle(.plain)

            // The whole reason the module exists. Inline, so answering never
            // costs a drill-in.
            if let pending = session.pending {
                HStack(spacing: 7) {
                    Text(pending.detail ?? pending.toolName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    CountdownText(deadline: pending.deadline)
                    DecisionButton(title: "Allow", isPrimary: true, accent: accent, action: onAllow)
                    DecisionButton(title: "Deny", isPrimary: false, accent: accent, action: onDeny)
                }
                .padding(.leading, 21)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(session.status == .waiting ? accent.opacity(0.14)
                                             : (hovering ? Color.white.opacity(0.05) : .clear)))
        .onHover { hovering = $0 }
    }

    private var statusText: String {
        switch session.status {
        case .waiting: return "needs you"
        case .working: return "working"
        case .idle:    return "idle"
        case .ended:   return "ended"
        }
    }
}

// MARK: - Pieces

private struct StatusDot: View {
    let status: AICodingSession.Status
    let accent: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
    }

    private var color: Color {
        switch status {
        case .waiting: return accent
        case .working: return Color(red: 0.40, green: 0.80, blue: 0.62)
        case .idle:    return .white.opacity(0.30)
        case .ended:   return .white.opacity(0.15)
        }
    }
}

private struct ToolChip: View {
    let name: String
    let accent: Color
    let emphasized: Bool

    var body: some View {
        Text(name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(emphasized ? .black : .white.opacity(0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(emphasized ? accent : Color.white.opacity(0.10)))
    }
}

private struct DecisionButton: View {
    let title: String
    let isPrimary: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isPrimary ? .black : .white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(isPrimary ? accent : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

/// Seconds left before the CLI gives up and falls back to its own prompt. Shown
/// because an Allow button with a hidden expiry is a button that sometimes
/// silently does nothing.
private struct CountdownText: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(deadline.timeIntervalSince(context.date).rounded()))
            Text("\(left)s")
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundColor(.white.opacity(left <= 5 ? 0.75 : 0.35))
        }
    }
}
