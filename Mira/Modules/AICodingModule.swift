// AICodingModule.swift
// Claude Code sessions in the notch, with Allow/Deny when the CLI is blocked.
//
// The panel has two independent sources, and keeping them independent is the
// whole design:
//
//   • ClaudeCodeSessionWatcher reads the transcripts Claude Code already writes
//     to ~/.claude/projects. This needs NOTHING installed, and it is where the
//     session list, titles, prompts, tool steps and token counts come from.
//   • AICodingBridgeService receives hook events over a Unix socket. It
//     contributes exactly one thing the filesystem cannot: a permission request
//     that is still blocked, and therefore still answerable.
//
// Layout follows MacNotch's: a detection banner when a live session is found
// and Mira can't act on it yet, then Active, then Recent. Each row carries the
// prompt you left off on, model and source chips, and its message and token
// cost — a title alone doesn't tell you which of four sessions you're looking at.

import SwiftUI
import Combine

// MARK: - Row

/// One session as the panel sees it: transcript facts, plus a pending ask when
/// the hook is installed and the CLI happens to be blocked right now.
struct AICodingRow: Identifiable, Equatable {
    let id: String
    let title: String
    let folder: String
    /// "Claude Code in Terminal" while running, the folder name once it's over.
    let source: String
    let isRunning: Bool
    let host: String?
    let branch: String?
    let modelLabel: String?
    let lastPrompt: String?
    let messageCount: Int
    let steps: [ClaudeCodeTranscript.Step]
    let tokens: ClaudeCodeTranscript.Tokens
    let lastActivity: Date
    let pending: PendingPermission?
    let isMidTool: Bool

    enum Status { case waiting, working, idle }

    var status: Status {
        if pending != nil { return .waiting }
        guard isRunning else { return .idle }
        let age = Date().timeIntervalSince(lastActivity)
        return age < ClaudeCodeSessionWatcher.activeWindow ? .working : .idle
    }

    /// Active means the process is alive. A session that exited is history even
    /// if it wrote a second ago.
    var isActive: Bool { isRunning || pending != nil }

    /// The tool it is running right now, if it's mid-tool. Shown in monospace
    /// under the prompt, the way the CLI itself would name it.
    var currentTool: String? {
        guard isMidTool, let last = steps.last else { return nil }
        return last.toolName
    }
}

// MARK: - Module

@MainActor
final class AICodingModule: NotchModule, ObservableObject {

    let id    = "aicoding"
    let title = "AI Coding"
    let icon  = "chevron.left.forwardslash.chevron.right"

    /// Grows when the panel is carrying something big. The detection banner is
    /// four lines and two buttons; at the standard height it pushed the session
    /// list down to a single visible row, so the panel advertised a session it
    /// then hid. Height is per-module by construction (NotchModule.swift), and
    /// this is exactly the case that was for.
    var heightLevel: NotchHeightLevel { (showsBanner || showingRemote || composed != nil) ? .tall : .standard }
    let allowsTallMode = true

    // MARK: Remote control

    private let remote = RemoteControlService.shared

    /// True while the notch-controlled conversation is on screen.
    @Published private(set) var showingRemote = false

    /// Where a new session should start. The folder you were last working in
    /// beats the home directory, which is almost never what you meant.
    var launchDirectory: String {
        watcher.transcripts.first(where: { !$0.cwd.isEmpty })?.cwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    func launchRemote() {
        remote.launch(in: launchDirectory)
        showingRemote = true
        heightChanged()
    }

    func openRemote()  { showingRemote = true;  heightChanged() }
    func closeRemote() { showingRemote = false; heightChanged() }

    // MARK: Detection banner

    /// Dismissed for this launch only. `bannerSuppressed` is the persistent one.
    @Published private(set) var bannerDismissed = false

    @AppStorage("mira_aicoding_banner_suppressed") var bannerSuppressed = false

    /// Only when all three hold: something is genuinely running, Mira can't act
    /// on it yet, and the user hasn't waved it away. A banner offering to
    /// connect to nothing is just chrome.
    var bannerRow: AICodingRow? {
        guard !installer.isInstalled, !bannerDismissed, !bannerSuppressed else { return nil }
        return activeRows.first { $0.isRunning }
    }

    var showsBanner: Bool { bannerRow != nil || justConnected }

    /// Briefly held after a successful Connect.
    ///
    /// Tre pressed Connect and reported "nothing happened". It had worked —
    /// script written, five events registered — but the only feedback was the
    /// banner silently vanishing and the panel shrinking, which reads as the
    /// thing you clicked dismissing itself. An action that edits the user's own
    /// config has to say so.
    @Published private(set) var justConnected = false

    func connect() {
        installer.install()
        guard installer.isInstalled else { heightChanged(); return }
        bridge.start()
        justConnected = true
        heightChanged()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.justConnected = false
            self?.heightChanged()
        }
    }

    func dismissBanner(forever: Bool) {
        if forever { bannerSuppressed = true } else { bannerDismissed = true }
        heightChanged()
    }

    /// The island sizes its hover zone from the panel height, so a height change
    /// that isn't announced leaves the panel collapsing when the cursor moves
    /// into the area that just appeared.
    func heightChanged() {
        NotificationCenter.default.post(name: .miraIslandHeightChanged, object: nil)
    }

    private let watcher   = ClaudeCodeSessionWatcher.shared
    private let bridge    = AICodingBridgeService.shared
    private let installer = AICodingHookInstaller.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: Write my prompt
    //
    // The non-coder entry point. The HeyClicky ads sell exactly this and never
    // show a terminal until it has already been filled in — the user says what
    // they want in their own words and never has to know what a good prompt
    // looks like.
    @Published var composeIntent = ""
    @Published private(set) var composing = false
    @Published private(set) var composed: PromptComposer.Composed?
    @Published private(set) var composeFailed = false

    func composePrompt() {
        let intent = composeIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty, !composing else { return }
        composing = true
        composeFailed = false
        composed = nil
        heightChanged()
        Task { [weak self] in
            let result = await PromptComposer.shared.compose(
                intent: intent, target: .claudeCode,
                apiKey: MiraState.effectiveAPIKeyStatic)
            await MainActor.run {
                guard let self else { return }
                self.composed = result
                self.composeFailed = (result == nil)
                self.composing = false
                self.heightChanged()
            }
        }
    }

    /// Sends only when the user says so — never as part of composing.
    func sendComposed() {
        guard let composed else { return }
        Task { await PromptComposer.shared.handOff(composed, to: .claudeCode) }
        openRemote()
        self.composed = nil
        composeIntent = ""
    }

    func discardComposed() {
        composed = nil
        composeFailed = false
        heightChanged()
    }

    @Published private(set) var detailSessionID: String?

    var detailTitle: String? {
        (detailSessionID != nil || showingRemote) ? "AI Coding" : nil
    }

    func popDetail() {
        if showingRemote { closeRemote() } else { detailSessionID = nil }
    }

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
                        source: t.sourceLabel,
                        isRunning: t.isRunning,
                        host: t.host,
                        branch: t.gitBranch,
                        modelLabel: t.modelLabel,
                        lastPrompt: t.lastPrompt,
                        messageCount: t.messageCount,
                        steps: t.steps,
                        tokens: t.tokens,
                        lastActivity: t.lastActivity,
                        pending: asks[t.id],
                        isMidTool: t.isMidTool)
        }
        .sorted { a, b in
            if (a.status == .waiting) != (b.status == .waiting) { return a.status == .waiting }
            if a.isActive != b.isActive { return a.isActive }
            return a.lastActivity > b.lastActivity
        }
    }

    var activeRows: [AICodingRow] { rows.filter(\.isActive) }

    /// Capped. Every session from the last twelve hours had a row here, so a
    /// busy day turned the panel into a wall of history and pushed "Resume in
    /// Terminal" roughly forty scroll-ticks below the fold. Three is what fits
    /// without scrolling; everything older is what the resume list is for.
    var recentRows: [AICodingRow] {
        Array(rows.filter { !$0.isActive }.prefix(3))
    }

    /// Resume rows for sessions not already on screen above. Listing a session
    /// twice in one panel makes the second list look like a rendering bug.
    var resumeRows: [ClaudeCodeSessionWatcher.ResumableSession] {
        let shown = Set((activeRows + recentRows).map(\.id))
        return watcher.resumable.filter { !shown.contains($0.id) }
    }

    var subtitle: NotchHeaderSubtitle? {
        if showingRemote {
            return NotchHeaderSubtitle(text: "Notch-controlled", isPill: true)
        }
        if let id = detailSessionID, let row = rows.first(where: { $0.id == id }) {
            return NotchHeaderSubtitle(text: row.folder, isPill: true)
        }
        let waiting = rows.filter { $0.status == .waiting }.count
        if waiting > 0 {
            return NotchHeaderSubtitle(text: waiting == 1 ? "1 waiting" : "\(waiting) waiting",
                                       isPill: true)
        }
        let active = activeRows.count
        if active > 0 { return NotchHeaderSubtitle(text: "\(active) active") }
        return NotchHeaderSubtitle(text: rows.isEmpty ? "no sessions" : "\(rows.count) recent")
    }

    /// Last announced banner state, so a session appearing or ending while the
    /// panel is open resizes it once rather than on every poll tick.
    private var lastShowsBanner = false

    init() {
        for p in [watcher.objectWillChange, bridge.objectWillChange,
                  installer.objectWillChange, remote.objectWillChange] {
            p.sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                // Deferred: these fire in objectWillChange, before the source's
                // own state has settled, so reading `showsBanner` here would
                // decide on the previous values.
                DispatchQueue.main.async {
                    let shows = self.showsBanner
                    guard shows != self.lastShowsBanner else { return }
                    self.lastShowsBanner = shows
                    self.heightChanged()
                }
            }
            .store(in: &cancellables)
        }
    }

    func didAppear() {
        installer.refresh()
        // Resumable history changes on the scale of hours, so it's read when
        // the panel opens rather than on the live poll.
        watcher.refreshResumable()
        // Poll harder while the panel is on screen; the background cadence set
        // at launch is deliberately lazy.
        watcher.stop()
        watcher.start(interval: 1.5)
        if installer.isInstalled { bridge.start() }
        // Cowork sessions change on the scale of minutes, so this stays lazy
        // even while the panel is open.
        if ClaudeCoworkSessionWatcher.shared.isAvailable {
            ClaudeCoworkSessionWatcher.shared.start(interval: 8)
        }
        AIAccountService.shared.refresh()
    }

    func didDisappear() {
        detailSessionID = nil
        watcher.stop()
        watcher.start(interval: 6)
    }

    func makeContent() -> AnyView {
        AnyView(AICodingView(module: self, watcher: watcher, bridge: bridge,
                             installer: installer, remote: remote))
    }
}

// MARK: - View

private struct AICodingView: View {

    @ObservedObject var module: AICodingModule
    @ObservedObject var watcher: ClaudeCodeSessionWatcher
    @ObservedObject var bridge: AICodingBridgeService
    @ObservedObject private var cowork = ClaudeCoworkSessionWatcher.shared
    @ObservedObject private var accounts = AIAccountService.shared
    @ObservedObject var installer: AICodingHookInstaller
    @ObservedObject var remote: RemoteControlService
    @ObservedObject private var accentSvc = AccentColorService.shared

    @State private var composer = ""
    @FocusState private var composeFieldFocused: Bool
    @FocusState private var composerFocused: Bool

    private var accent: Color { accentSvc.color }

    var body: some View {
        Group {
            if module.showingRemote {
                remoteControl
            } else if let id = module.detailSessionID, let row = module.rows.first(where: { $0.id == id }) {
                detail(row)
            } else {
                list
            }
        }
        .padding(.top, NotchModuleShellView.headerHeight + 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(Color.black)
    }

    // MARK: Detection banner

    @ViewBuilder
    private var banner: some View {
        if module.justConnected {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color(red: 0.40, green: 0.80, blue: 0.62))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Connected")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))
                    Text("Tool prompts from Claude Code now land here. "
                         + "Sessions already running keep their own prompts until you restart them.")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(Color(red: 0.40, green: 0.80, blue: 0.62).opacity(0.12)))
        } else if let row = module.bannerRow {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12))
                        .foregroundColor(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude Code detected in \(row.host ?? "Terminal")")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.95))
                        // Says exactly what pressing the button changes. The
                        // one thing this must not do is imply Mira will take
                        // over the session — it only answers prompts.
                        Text("Running \(row.folder). Allow and deny its prompts from the notch? "
                             + "Mira adds a hook to ~/.claude/settings.json and changes nothing else.")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        module.connect()
                    } label: {
                        Text("Connect")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(accent))
                    }
                    .buttonStyle(.plain)

                    Button {
                        module.dismissBanner(forever: false)
                    } label: {
                        Text("Not now")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                }

                Button("Don't ask again") { module.dismissBanner(forever: true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(maxWidth: .infinity)

                if let error = installer.lastError {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.45))
                        .lineLimit(2)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(accent.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(accent.opacity(0.55), lineWidth: 1))
            )
        }
    }

    // MARK: Remote control entry

    /// The one row that starts a session Mira owns end to end. Gated on the
    /// hook, because a --print session has no terminal to fall back to: without
    /// the hook there is nowhere for a tool prompt to be answered, and the run
    /// would stall on the first Bash call with no explanation.
    @ViewBuilder
    private var remoteControlEntry: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Remote control")

            Button {
                if remote.phase.isLive { module.openRemote() } else { module.launchRemote() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: remote.phase.isLive ? "bolt.fill" : "plus.circle")
                        .font(.system(size: 12))
                        .foregroundColor(accent)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(remote.phase.isLive ? "Notch-controlled session" : "Launch new session")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.92))
                        Text(remote.phase.isLive
                             ? "Open the conversation"
                             : "Open Claude Code with notch control in \(URL(fileURLWithPath: module.launchDirectory).lastPathComponent)")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.30))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .disabled(!installer.isInstalled || !remote.isAvailable)
            .opacity((installer.isInstalled && remote.isAvailable) ? 1 : 0.4)

            if !remote.isAvailable {
                Text("Claude Code isn't installed on this Mac.")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
            } else if !installer.isInstalled {
                Text("Connect first — a notch-controlled session has no terminal to ask in, "
                     + "so it needs the hook to approve tools.")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Remote control conversation

    /// The approval for THIS session, if it's blocked right now. Joined by id,
    /// same as the list does.
    private var remotePending: PendingPermission? {
        guard let id = remote.sessionID else { return nil }
        return bridge.sessions.first { $0.id == id }?.pending
    }

    /// Approving has to be possible from inside this view. The first cut only
    /// rendered Allow/Deny in the session list, so a notch-controlled session
    /// that asked while you were reading its conversation had no answerable
    /// prompt anywhere on screen — it sat at "Working…" and then timed out.
    @ViewBuilder
    private var remoteApproval: some View {
        if let pending = remotePending, let id = remote.sessionID {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ToolChip(name: pending.toolName, accent: accent, emphasized: true)
                    Text("needs your approval")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer(minLength: 0)
                    CountdownText(deadline: pending.deadline)
                }
                if let detail = pending.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    DecisionButton(title: "Allow", isPrimary: true, accent: accent) {
                        bridge.respond(sessionID: id, approve: true)
                    }
                    DecisionButton(title: "Deny", isPrimary: false, accent: accent) {
                        bridge.respond(sessionID: id, approve: false)
                    }
                }
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(accent.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(accent.opacity(0.5), lineWidth: 1))
            )
        }
    }

    private var remoteControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusStrip
            remoteApproval

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(remote.messages) { message in
                            RemoteMessageRow(message: message, accent: accent)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: remote.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            composerBar
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(remote.phase == .working ? accent : Color(red: 0.40, green: 0.80, blue: 0.62))
                .frame(width: 5, height: 5)

            Text(statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.7))

            if let model = remote.model {
                Chip(text: model.replacingOccurrences(of: "claude-", with: ""),
                     tint: Color(red: 0.98, green: 0.62, blue: 0.30))
            }

            Spacer(minLength: 0)

            if remote.costUSD > 0 {
                Text(String(format: "$%.3f", remote.costUSD))
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.35))
            }

            // Hands the conversation back rather than abandoning it — resumes
            // this same session id in Terminal.
            if remote.sessionID != nil, remote.phase.isLive {
                Button("Continue in Terminal") { remote.continueInTerminal(); module.closeRemote() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(accent)
            }

            if remote.phase.isLive {
                Button("Stop") { remote.stop() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
            } else {
                Button("Relaunch") { module.launchRemote() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(accent)
            }
        }
    }

    private var statusText: String {
        switch remote.phase {
        case .idle:              return "Not running"
        case .launching:         return "Starting Claude Code…"
        case .ready:             return "Ready"
        case .working:           return "Working…"
        case .ended(let reason): return reason ?? "Session ended"
        }
    }

    private var composerBar: some View {
        HStack(spacing: 7) {
            TextField("Ask Claude Code…", text: $composer, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1...3)
                .focused($composerFocused)
                .onSubmit(sendComposer)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))

            Button(action: sendComposer) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(accent))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.35)
        }
        .opacity(remote.phase.isLive ? 1 : 0.4)
        .disabled(!remote.phase.isLive)
    }

    private var canSend: Bool {
        remote.phase.isLive && !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendComposer() {
        guard canSend else { return }
        remote.send(composer)
        composer = ""
        composerFocused = true
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 7) {
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
                VStack(alignment: .leading, spacing: 7) {
                    banner
                    remoteControlEntry

                    if !module.activeRows.isEmpty {
                        SectionLabel("Active")
                        ForEach(module.activeRows) { row in
                            SessionRow(row: row, accent: accent,
                                       onOpen: { module.show(row.id) },
                                       onAllow: { bridge.respond(sessionID: row.id, approve: true) },
                                       onDeny:  { bridge.respond(sessionID: row.id, approve: false) })
                        }
                    }

                    if !module.recentRows.isEmpty {
                        SectionLabel("Recent")
                        ForEach(module.recentRows) { row in
                            SessionRow(row: row, accent: accent,
                                       onOpen: { module.show(row.id) },
                                       onAllow: {}, onDeny: {})
                        }
                    }

                    composeSection
                    accountsSection
                    coworkList
                    resumeList
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
    }

    // MARK: Write my prompt

    /// Say what you want in plain words; Mira writes the prompt.
    @ViewBuilder
    private var composeSection: some View {
        SectionLabel("Write my prompt")

        if let composed = module.composed {
            VStack(alignment: .leading, spacing: 6) {
                // What Mira THOUGHT it saw, above the prompt. A misread screen
                // is visible here, before anything runs — not afterwards in a
                // diff.
                if !composed.understoodContext.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "eye")
                            .font(.system(size: 9))
                        Text(composed.understoodContext)
                            .font(.system(size: 9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundColor(.white.opacity(0.42))
                }

                ScrollView {
                    Text(composed.prompt)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)

                HStack(spacing: 7) {
                    Button { module.sendComposed() } label: {
                        Text("Send to Claude Code")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(accent))
                    }
                    .buttonStyle(.plain)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(composed.prompt, forType: .string)
                    } label: {
                        Text("Copy")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)

                    Button { module.discardComposed() } label: {
                        Text("Discard")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
        } else {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    TextField("What do you want to build or change?",
                              text: $module.composeIntent)
                        .textFieldStyle(.plain)
                        .focused($composeFieldFocused)
                        .onReceive(NotificationCenter.default.publisher(for: .miraFocusComposer)) { _ in
                            composeFieldFocused = true
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.9))
                        .onSubmit { module.composePrompt() }

                    if module.composing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { module.composePrompt() } label: {
                            Text("Write it")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(accent))
                        }
                        .buttonStyle(.plain)
                        .disabled(module.composeIntent.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Text(module.composeFailed
                     ? "Couldn't write that one — try saying it a different way."
                     : "Mira looks at your screen and writes the prompt, with safety rules built in. You approve it before it runs.")
                    .font(.system(size: 9))
                    .foregroundColor(module.composeFailed
                                     ? Color(red: 0.95, green: 0.55, blue: 0.5)
                                     : .white.opacity(0.34))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.045)))
        }
    }

    // MARK: Accounts

    /// Which accounts the CLI lanes are running on.
    ///
    /// Only the CLI side of Mira uses the user's own subscription — chat, voice
    /// and vision still go through Mira's backend. So this lives HERE, in the
    /// module that spawns those CLIs, rather than in Settings where it would
    /// read as a claim about the whole app.
    @ViewBuilder
    private var accountsSection: some View {
        SectionLabel("Your accounts")
        VStack(spacing: 4) {
            accountRow(.claude, name: "Claude", symbol: "sparkle",
                       state: accounts.claude)
            accountRow(.codex, name: "ChatGPT / Codex", symbol: "chevron.left.slash.chevron.right",
                       state: accounts.codex)
        }
        Text("Claude Code and Codex sign in themselves, against your own plan. "
             + "Mira spawns them and never sees your login.")
            .font(.system(size: 9))
            .foregroundColor(.white.opacity(0.32))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.top, 1)
    }

    private func accountRow(_ provider: AIAccountService.Provider,
                            name: String,
                            symbol: String,
                            state: AIAccountService.State) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundColor(state.isConnected ? accent : .white.opacity(0.35))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                Text(Self.stateLabel(state, provider: provider))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.40))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Nothing to offer when the CLI isn't installed — a Connect button
            // that opens a login for a missing binary is a dead end.
            if case .notInstalled = state {
                EmptyView()
            } else if !state.isConnected {
                Button { accounts.connect(provider) } label: {
                    Text("Connect")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)
                .help("Opens \(name)'s own sign-in in Terminal")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(accent.opacity(0.9))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.045)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(Self.stateLabel(state, provider: provider))")
    }

    private static func stateLabel(_ state: AIAccountService.State,
                                   provider: AIAccountService.Provider) -> String {
        switch state {
        case .notInstalled:            return AIAccountService.installHint(for: provider)
        case .signedOut:               return "Installed — not signed in"
        case .connected(let detail):   return detail.map { "Connected · \($0)" } ?? "Connected"
        }
    }

    // MARK: Claude Cowork

    /// Cowork sessions from Claude Desktop. Listed, not driven: these run inside
    /// Claude Desktop's own sandbox, their `cwd` is a path in that sandbox
    /// rather than on this Mac, and there is no documented way to attach to one.
    /// So the row says what is there and stops — offering an "open" that could
    /// not work would be worse than not offering it.
    @ViewBuilder
    private var coworkList: some View {
        if !cowork.sessions.isEmpty {
            SectionLabel("Claude Cowork")
            ForEach(cowork.sessions.prefix(6)) { session in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 11))
                        .foregroundColor(accent.opacity(0.8))
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.88))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(Self.ago(session.lastActivity))
                            if let model = session.shortModel { Text("· \(model)") }
                        }
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.38))
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.045)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Cowork session \(session.displayName)")
            }
        }
    }

    private static func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60    { return "just now" }
        if seconds < 3600  { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    // MARK: Resume in Terminal

    /// Older work, one row per project, handed back to a real terminal rather
    /// than reopened here. Resuming into the notch would mean two owners of one
    /// session — the CLI refuses that, and it isn't what you want anyway when
    /// you're going back to something you were mid-way through.
    @ViewBuilder
    private var resumeList: some View {
        if !module.resumeRows.isEmpty {
            SectionLabel("Resume in Terminal")
            ForEach(module.resumeRows) { session in
                Button {
                    RemoteControlService.resumeInTerminal(sessionID: session.id,
                                                          directory: session.cwd)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 22, height: 22)
                            .overlay(Image(systemName: "terminal")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5)))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.88))
                                .lineLimit(1)
                            Text(session.lastPrompt
                                 ?? "Last active \(SessionRow.relative(session.lastActivity)) ago")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 6)

                        Text(SessionRow.relative(session.lastActivity))
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.35))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.28))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Resume in Terminal — \(session.cwd)")
            }
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

            Text(installer.isInstalled ? "Allow/Deny enabled" : "Read-only")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.40))

            Spacer(minLength: 0)

            if watcher.liveProcessCount > 0 {
                Text("\(watcher.liveProcessCount) running")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.30))
            }
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
                    Label(row.source, systemImage: "terminal")
                    if let branch = row.branch, branch != "HEAD" {
                        Label(branch, systemImage: "arrow.triangle.branch")
                    }
                    Label("\(row.messageCount) msgs · \(Self.compact(row.tokens.billable)) tok",
                          systemImage: "number")
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

// MARK: - Section label

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white.opacity(0.32))
            .padding(.top, 2)
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
                HStack(alignment: .top, spacing: 8) {
                    icon

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(row.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.92))
                                .lineLimit(1)

                            if row.status == .waiting {
                                Chip(text: "Waiting", tint: accent, filled: true)
                            }
                            if let model = row.modelLabel {
                                Chip(text: model, tint: Color(red: 0.98, green: 0.62, blue: 0.30))
                            }
                            Chip(text: "CLI", tint: .white.opacity(0.45))
                        }

                        // Where you left off. Falls back to the source line so
                        // a session with no recorded prompt still says what and
                        // where it is.
                        Text(row.lastPrompt ?? row.source)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if let tool = row.currentTool {
                            Text(tool)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white.opacity(0.38))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 6)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.relative(row.lastActivity))
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.42))
                        Text("\(row.messageCount) msgs · \(AICodingView.compact(row.tokens.billable)) tok")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.28))
                    }
                    .fixedSize()
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
                .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(row.status == .waiting ? accent.opacity(0.14)
                                         : (hovering ? Color.white.opacity(0.05) : .clear)))
        .onHover { hovering = $0 }
    }

    /// Terminal glyph with a liveness dot, so the row reads as a running thing
    /// before any text is parsed.
    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(0.08))
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                )
            if row.status != .idle {
                Circle()
                    .fill(row.status == .waiting ? accent
                                                 : Color(red: 0.40, green: 0.80, blue: 0.62))
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1.2))
                    .offset(x: 2, y: 2)
            }
        }
    }

    /// Coarse and short — this column is 60pt wide and "4 mths" is as much as
    /// anyone needs from a session they finished in April.
    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<10:      return "now"
        case ..<60:      return "\(Int(seconds))s"
        case ..<3600:    return "\(Int(seconds / 60))m"
        case ..<86400:   return "\(Int(seconds / 3600))h"
        case ..<2592000: return "\(Int(seconds / 86400))d"
        default:         return "\(Int(seconds / 2592000)) mths"
        }
    }
}

// MARK: - Remote message

private struct RemoteMessageRow: View {

    let message: RemoteControlService.Message
    let accent: Color

    var body: some View {
        switch message.role {
        case .user:
            // Right-aligned and tinted, so your own turns are findable when
            // scrolling back through a long run of tool calls.
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.22)))
            }

        case .assistant:
            Text(message.text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .tool:
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.35))
                Text(message.text)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

        case .system:
            Text(message.text)
                .font(.system(size: 10))
                .foregroundColor(Color(red: 0.95, green: 0.55, blue: 0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Pieces

private struct Chip: View {
    let text: String
    var tint: Color = .white
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(filled ? .black : tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(filled ? tint : tint.opacity(0.16)))
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
