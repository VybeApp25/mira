// AICodingModule.swift
// Claude Code sessions in the notch, with Allow/Deny when the CLI is blocked.
//
// The panel has two independent sources, and keeping them independent is the
// whole design:
//
//   • ClaudeCodeSessionWatcher reads the transcripts Claude Code already writes
//     to ~/.claude/projects. This needs NOTHING installed, and it is where the
//     session list, titles, tool steps and token counts come from.
//   • AICodingBridgeService receives hook events over a Unix socket. It
//     contributes exactly one thing the filesystem cannot: a permission request
//     that is still blocked, and therefore still answerable.
//
// The first cut of this module had only the second source and required the
// hook, so a running session was invisible until the user edited their own
// settings.json. MacNotch's own copy says it the right way round — "Works via
// file monitoring, hooks are optional for faster event notifications."
//
// The panel is deliberately dull when nothing needs you. A waiting session is
// the only state that gets color, because a permission prompt you scroll past
// is a permission prompt you approve without reading.

import SwiftUI
import Combine

// MARK: - Row

/// One session as the panel sees it: transcript facts, plus a pending ask when
/// the hook is installed and the CLI happens to be blocked right now.
struct AICodingRow: Identifiable, Equatable {
    let id: String
    let title: String
    let folder: String
    let branch: String?
    let model: String?
    let steps: [ClaudeCodeTranscript.Step]
    let tokens: ClaudeCodeTranscript.Tokens
    let lastActivity: Date
    let pending: PendingPermission?
    let isMidTool: Bool

    enum Status { case waiting, working, idle }

    var status: Status {
        if pending != nil { return .waiting }
        let age = Date().timeIntervalSince(lastActivity)
        if age < ClaudeCodeSessionWatcher.activeWindow { return .working }
        return .idle
    }
}

// MARK: - Module

@MainActor
final class AICodingModule: NotchModule, ObservableObject {

    let id    = "aicoding"
    let title = "AI Coding"
    let icon  = "chevron.left.forwardslash.chevron.right"

    let heightLevel: NotchHeightLevel = .standard
    let allowsTallMode = true

    private let watcher   = ClaudeCodeSessionWatcher.shared
    private let bridge    = AICodingBridgeService.shared
    private let installer = AICodingHookInstaller.shared
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var detailSessionID: String?

    var detailTitle: String? { detailSessionID == nil ? nil : "AI Coding" }
    func popDetail() { detailSessionID = nil }
    func show(_ id: String) { detailSessionID = id }

    /// Transcript sessions with any live permission ask merged in by id. The
    /// hook's `session_id` is the same UUID Claude Code names the transcript
    /// after, so this join needs no correlation heuristics.
    var rows: [AICodingRow] {
        let asks = Dictionary(uniqueKeysWithValues:
            bridge.sessions.compactMap { session -> (String, PendingPermission)? in
                guard let pending = session.pending else { return nil }
                return (session.id, pending)
            })

        return watcher.transcripts.map { t in
            AICodingRow(id: t.id,
                        title: t.displayName,
                        folder: t.folderName,
                        branch: t.gitBranch,
                        model: t.model,
                        steps: t.steps,
                        tokens: t.tokens,
                        lastActivity: t.lastActivity,
                        pending: asks[t.id],
                        isMidTool: t.isMidTool)
        }
        .sorted { a, b in
            // Anything blocked on a human outranks recency: it is the only row
            // with a deadline attached.
            if (a.status == .waiting) != (b.status == .waiting) { return a.status == .waiting }
            return a.lastActivity > b.lastActivity
        }
    }

    var subtitle: NotchHeaderSubtitle? {
        if let id = detailSessionID, let row = rows.first(where: { $0.id == id }) {
            return NotchHeaderSubtitle(text: row.folder, isPill: true)
        }
        let waiting = rows.filter { $0.status == .waiting }.count
        if waiting > 0 {
            return NotchHeaderSubtitle(text: waiting == 1 ? "1 waiting" : "\(waiting) waiting",
                                       isPill: true)
        }
        let working = rows.filter { $0.status == .working }.count
        if working > 0 { return NotchHeaderSubtitle(text: "\(working) active") }
        return NotchHeaderSubtitle(text: rows.isEmpty ? "no sessions" : "\(rows.count) recent")
    }

    init() {
        for p in [watcher.objectWillChange, bridge.objectWillChange, installer.objectWillChange] {
            p.sink { [weak self] _ in self?.objectWillChange.send() }
             .store(in: &cancellables)
        }
    }

    func didAppear() {
        installer.refresh()
        // Poll harder while the panel is on screen; the background cadence set
        // at launch is deliberately lazy.
        watcher.stop()
        watcher.start(interval: 1.5)
        if installer.isInstalled { bridge.start() }
    }

    func didDisappear() {
        detailSessionID = nil
        watcher.stop()
        watcher.start(interval: 6)
    }

    func makeContent() -> AnyView {
        AnyView(AICodingView(module: self, watcher: watcher, bridge: bridge, installer: installer))
    }
}

// MARK: - View

private struct AICodingView: View {

    @ObservedObject var module: AICodingModule
    @ObservedObject var watcher: ClaudeCodeSessionWatcher
    @ObservedObject var bridge: AICodingBridgeService
    @ObservedObject var installer: AICodingHookInstaller
    @ObservedObject private var accentSvc = AccentColorService.shared

    @State private var showingSetup = false

    private var accent: Color { accentSvc.color }

    var body: some View {
        Group {
            if let id = module.detailSessionID, let row = module.rows.first(where: { $0.id == id }) {
                detail(row)
            } else if showingSetup {
                setup
            } else {
                list
            }
        }
        .padding(.top, NotchModuleShellView.headerHeight + 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(Color.black)
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            if module.rows.isEmpty {
                Text(watcher.isAvailable
                     ? "No Claude Code sessions in the last 12 hours. Start one in a terminal and it shows up here."
                     : "Claude Code isn't installed, or has never run on this Mac.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(module.rows) { row in
                        SessionRow(row: row,
                                   accent: accent,
                                   onOpen: { module.show(row.id) },
                                   onAllow: { bridge.respond(sessionID: row.id, approve: true) },
                                   onDeny:  { bridge.respond(sessionID: row.id, approve: false) })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
    }

    /// One line about what the panel can and can't do right now. Without the
    /// hook the list is read-only, and saying so beats letting someone wait for
    /// an Allow button that will never appear.
    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(installer.isInstalled ? Color(red: 0.40, green: 0.80, blue: 0.62)
                                            : Color.white.opacity(0.25))
                .frame(width: 5, height: 5)

            Text(installer.isInstalled
                 ? "Allow/Deny enabled"
                 : "Read-only — turn on Allow/Deny to answer prompts here")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.40))

            if !installer.isInstalled {
                Button("Set up") { showingSetup = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(accent)
            }

            Spacer(minLength: 0)

            if watcher.liveProcessCount > 0 {
                Text("\(watcher.liveProcessCount) running")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.30))
            }
        }
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Answer Claude Code from the notch")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))

            Text("Sessions already show up without this. To also allow or deny a command "
                 + "from here, Mira installs a hook script and adds it to ~/.claude/settings.json.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Text("Your other hooks are left alone. Nothing is sent anywhere — the hook talks "
                 + "to Mira over a local socket only you can read, and if Mira isn't running "
                 + "your CLI prompts exactly as it does today.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    installer.install()
                    if installer.isInstalled { bridge.start(); showingSetup = false }
                } label: {
                    Text("Enable Allow/Deny")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)

                Button("Not now") { showingSetup = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))

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

    // MARK: Detail

    private func detail(_ row: AICodingRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let pending = row.pending {
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
                                AICodingBridgeService.shared.respond(sessionID: row.id, approve: true)
                                module.popDetail()
                            }
                            DecisionButton(title: "Deny", isPrimary: false, accent: accent) {
                                AICodingBridgeService.shared.respond(sessionID: row.id, approve: false)
                                module.popDetail()
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    if let branch = row.branch, branch != "HEAD" {
                        Label(branch, systemImage: "arrow.triangle.branch")
                    }
                    if let model = row.model {
                        Label(model, systemImage: "cpu")
                    }
                    Label("\(Self.compact(row.tokens.billable)) tokens", systemImage: "number")
                }
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.40))
                .labelStyle(.titleAndIcon)

                Text("RECENT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.32))

                // Newest first, five rows — one tool per row, matching how the
                // steps read in the transcript.
                ForEach(row.steps.suffix(5).reversed()) { step in
                    HStack(alignment: .top, spacing: 6) {
                        ToolChip(name: step.toolName, accent: accent, emphasized: false)
                        // No placeholder when there's nothing to say. A column of
                        // em dashes reads as data that failed to load.
                        if let detail = step.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }

                if row.steps.isEmpty {
                    Text("No tool calls in this session yet.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Row

private struct SessionRow: View {

    let row: AICodingRow
    let accent: Color
    let onOpen: () -> Void
    let onAllow: () -> Void
    let onDeny: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: onOpen) {
                HStack(spacing: 7) {
                    StatusDot(status: row.status, accent: accent)

                    Text(row.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)

                    Text(row.folder)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if let last = row.steps.last, row.status != .waiting {
                        Text(last.toolName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.42))
                    }

                    Text(AICodingView.compact(row.tokens.billable))
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.28))
                }
            }
            .buttonStyle(.plain)

            // The whole reason the module exists. Inline, so answering never
            // costs a drill-in.
            if let pending = row.pending {
                HStack(spacing: 7) {
                    ToolChip(name: pending.toolName, accent: accent, emphasized: true)
                    Text(pending.detail ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    CountdownText(deadline: pending.deadline)
                    DecisionButton(title: "Allow", isPrimary: true, accent: accent, action: onAllow)
                    DecisionButton(title: "Deny", isPrimary: false, accent: accent, action: onDeny)
                }
                .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(row.status == .waiting ? accent.opacity(0.14)
                                         : (hovering ? Color.white.opacity(0.05) : .clear)))
        .onHover { hovering = $0 }
    }
}

// MARK: - Pieces

private struct StatusDot: View {
    let status: AICodingRow.Status
    let accent: Color

    var body: some View {
        Circle().fill(color).frame(width: 5, height: 5)
    }

    private var color: Color {
        switch status {
        case .waiting: return accent
        case .working: return Color(red: 0.40, green: 0.80, blue: 0.62)
        case .idle:    return .white.opacity(0.28)
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
