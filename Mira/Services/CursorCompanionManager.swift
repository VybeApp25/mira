import AppKit
import SwiftUI

// MARK: - Manager

/// Owns the floating NSPanel that surfaces agent progress, short replies,
/// questions, confirmations, and success/error states near the user's cursor.
/// All other modules post events via send(_:); the manager drives the view model
/// which SwiftUI observes reactively.
@MainActor
final class CursorCompanionManager {

    static let shared = CursorCompanionManager()

    let viewModel = CursorCompanionViewModel()

    private var panel:       NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var followTask:  Task<Void, Never>?   // active only during agentRunning
    private var appearTime:  Date?

    // Preserved across rapid progress updates so the title stays stable
    private var currentAgentTitle  = ""
    private var currentAgentTotal  = 0
    private var currentAgentJobId: UUID?

    private init() {}

    // MARK: - Public entry point

    func send(_ event: CursorCompanionEvent) {
        switch event {

        case .chatReply(let text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            show(.reply(text: t))

        case .agentStarted(let title, let total):
            currentAgentTitle = title
            currentAgentTotal = total
            show(.agentRunning(title: title, step: "Starting…", current: 0, total: total, progress: 0))

        case .agentProgress(let step, let current, let total, let progress):
            let title = currentAgentTitle.isEmpty ? "Working…" : currentAgentTitle
            let t     = total > 0 ? total : currentAgentTotal
            show(.agentRunning(title: title, step: step, current: current, total: t, progress: progress))

        case .agentCompleted(let title, let actions):
            currentAgentTitle = ""
            currentAgentTotal = 0
            show(.success(title: title, actions: actions))

        case .agentFailed(let message, let actions):
            currentAgentTitle = ""
            show(.error(message: message, recoverable: !actions.isEmpty, actions: actions))

        case .question(let text, let options, let jobId):
            currentAgentJobId = jobId
            show(.question(text: text, options: options, jobId: jobId))

        case .confirmation(let summary, let actions):
            show(.confirmation(summary: summary, actions: actions))

        case .success(let title, let actions):
            show(.success(title: title, actions: actions))

        case .error(let msg, let recoverable, let actions):
            show(.error(message: msg, recoverable: recoverable, actions: actions))

        case .dismiss:
            hide()
        }
    }

    // MARK: - Action dispatch

    func handleAction(tag: String) {
        CursorCompanionTelemetry.shared.actionTapped(tag)
        TelemetryService.shared.track(.companionActionTapped(action: tag))

        switch tag {
        case "open_island":
            NotificationCenter.default.post(name: .miraActivateText, object: nil)
            hide()

        case "view_library":
            NotificationCenter.default.post(name: .miraTabSelected, object: nil,
                                             userInfo: ["tab": "projects"])
            NotificationCenter.default.post(name: .miraActivateText, object: nil)
            hide()

        case "open_site":
            if let jobId = currentAgentJobId,
               let job   = AgentJobStore.shared.job(id: jobId),
               let str   = job.result?.metadata["deployedUrl"] ?? job.result?.metadata["publishedUrl"],
               let url   = URL(string: str) {
                NSWorkspace.shared.open(url)
            }
            hide()

        case "reconnect":
            NotificationCenter.default.post(name: .miraActivateText, object: nil)
            hide()

        case "confirm":
            var info: [AnyHashable: Any] = [:]
            if let jobId = currentAgentJobId { info["jobId"] = jobId }
            NotificationCenter.default.post(name: .companionDidConfirm, object: nil, userInfo: info)
            hide()

        case "cancel":
            var info: [AnyHashable: Any] = [:]
            if let jobId = currentAgentJobId { info["jobId"] = jobId }
            NotificationCenter.default.post(name: .companionDidCancel, object: nil, userInfo: info)
            hide()

        case "dismiss":
            hide()

        default:
            NotificationCenter.default.post(name: .companionActionTapped, object: nil,
                                             userInfo: ["tag": tag])
            hide()
        }
    }

    // MARK: - Show / Hide

    private func show(_ newState: CursorCompanionState) {
        dismissTask?.cancel()
        dismissTask = nil

        let wasIdle   = viewModel.state == .idle
        let cursor    = NSEvent.mouseLocation

        viewModel.state = newState
        ensurePanel()
        guard let p = panel else { return }

        let size   = estimatedSize(for: newState)
        let origin = position(for: cursor, size: size)
        let frame  = CGRect(origin: origin, size: size)

        p.ignoresMouseEvents = !newState.isInteractive

        if wasIdle || p.alphaValue < 0.05 {
            p.setFrame(frame, display: false)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 1.0
            }
            appearTime = .now
            CursorCompanionTelemetry.shared.appeared(state: newState.stateLabel)
            TelemetryService.shared.track(.companionShown(state: newState.stateLabel))
        } else {
            // Already visible — reposition to current cursor on state changes
            p.setFrame(frame, display: true, animate: true)
        }

        // Follow cursor for all visible states — reply, agent, confirmation, etc.
        // This makes the bubble feel truly attached to the cursor like HeyClicky.
        if newState != .idle {
            startFollowing()
        } else {
            stopFollowing()
        }

        if let delay = newState.autoDismissDelay, !viewModel.isPinned {
            scheduleDismiss(after: delay)
        }
    }

    func hide() {
        guard let p = panel, p.alphaValue > 0.01 else {
            viewModel.state = .idle
            return
        }
        dismissTask?.cancel()
        dismissTask = nil
        stopFollowing()

        if let start = appearTime {
            let elapsed = Date().timeIntervalSince(start)
            let label   = viewModel.state.stateLabel
            CursorCompanionTelemetry.shared.dismissed(state: label, after: elapsed)
            TelemetryService.shared.track(.companionDismissed(state: label, afterSeconds: elapsed))
        }
        appearTime = nil

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            p.orderOut(nil)
            self?.viewModel.state = .idle
        }
    }

    // MARK: - Follow Mode

    private func startFollowing() {
        guard followTask == nil else { return }   // already tracking
        followTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 16_000_000)  // 60 fps — feels attached
                guard let self, !Task.isCancelled else { return }
                // Keep following as long as the bubble is visible. Do NOT gate on
                // alphaValue: during the 0.2s fade-in alpha is still < 0.5 on the
                // first ticks, which would kill the loop immediately and leave the
                // bubble frozen at its spawn point (detaches as the cursor moves).
                // Dismissal already stops the loop via hide() -> stopFollowing().
                guard self.viewModel.state != .idle,
                      let p = self.panel, p.isVisible else {
                    self.stopFollowing()
                    return
                }
                let cursor    = NSEvent.mouseLocation
                let size      = self.estimatedSize(for: self.viewModel.state)
                let newOrigin = self.position(for: cursor, size: size)
                let dist = hypot(newOrigin.x - p.frame.origin.x,
                                 newOrigin.y - p.frame.origin.y)
                if dist > 2 {
                    p.setFrameOrigin(newOrigin)
                }
            }
        }
    }

    private func stopFollowing() {
        followTask?.cancel()
        followTask = nil
    }

    // MARK: - Panel

    private func ensurePanel() {
        guard panel == nil else { return }

        let vm      = viewModel
        let content = CursorCompanionContent(viewModel: vm, tailDir: tailDir) { [weak self] tag in
            self?.handleAction(tag: tag)
        }

        let p = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: 80),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        // Above the island (statusBar+10) so progress is always visible
        p.level              = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 11)
        p.backgroundColor    = .clear
        p.isOpaque           = false
        p.hasShadow          = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView        = NSHostingView(rootView: content)
        panel = p
    }

    // MARK: - Positioning

    private func position(for cursor: CGPoint, size: CGSize) -> CGPoint {
        let screen  = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main!
        let visible = screen.visibleFrame
        // Gap between the cursor and the bubble's near edge. ~64pt ≈ half an inch
        // on a 2x ~128 pt/inch display. Tune here to move the bubble closer/farther.
        let offset: CGFloat = 64

        // Default: right of cursor, vertically centered on cursor
        var x = cursor.x + offset
        var y = cursor.y - size.height / 2
        var tailIsLeft = true

        // Flip left when near right edge
        if x + size.width + 8 > visible.maxX {
            x = cursor.x - offset - size.width
            tailIsLeft = false
        }
        // Push down when panel top exceeds visible frame
        if y + size.height + 8 > visible.maxY {
            y = visible.maxY - size.height - 8
        }
        // Push up when panel bottom goes off screen
        if y < visible.minY + 8 {
            y = visible.minY + 8
        }
        // Final left-edge clamp
        x = max(visible.minX + 8, x)

        if tailDir.tailOnLeft != tailIsLeft { tailDir.tailOnLeft = tailIsLeft }

        return CGPoint(x: x, y: y)
    }

    // MARK: - Size estimation

    private func estimatedSize(for state: CursorCompanionState) -> CGSize {
        switch state {
        case .idle:                            return CGSize(width: 1, height: 1)
        case .reply(let t):
            // Reply bubble is 240pt wide (see CursorCompanionView). Estimate height
            // from char count at that width (~28 chars/line at 13pt); slightly
            // over-estimate so the panel never clips the typewriter text.
            let charsPerLine: Double = 28
            let lines = max(1, ceil(Double(t.count) / charsPerLine))
            let h = lines * 22 + 34     // 22pt per line + padding
            return CGSize(width: 240, height: h)
        case .agentRunning:                    return CGSize(width: 300, height: 90)
        case .question(_, let opts, _):        return CGSize(width: 300, height: CGFloat(56 + opts.count * 40))
        case .confirmation:                    return CGSize(width: 300, height: 108)
        case .success(_, let a):               return CGSize(width: 300, height: a.isEmpty ? 52 : CGFloat(52 + 38))
        case .error(_, _, let a):              return CGSize(width: 300, height: a.isEmpty ? 56 : CGFloat(56 + 38))
        }
    }

    // MARK: - Auto-dismiss with hover pause

    private func scheduleDismiss(after delay: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            var countdown = delay
            let tick: TimeInterval = 0.1
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard !self.viewModel.isPinned else { return }
                if let p = self.panel, p.frame.contains(NSEvent.mouseLocation) {
                    countdown = delay   // reset full delay while hovered
                } else {
                    countdown -= tick
                }
            }
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    // MARK: - Tail direction

    private let tailDir = TailDirectionBinding()
}

// MARK: - Tail direction observable

@MainActor
final class TailDirectionBinding: ObservableObject {
    @Published var tailOnLeft: Bool = true
}

// MARK: - SwiftUI bridge

/// Thin struct that connects the view model to the view.
struct CursorCompanionContent: View {
    @ObservedObject var viewModel: CursorCompanionViewModel
    @ObservedObject var tailDir: TailDirectionBinding
    let onAction: (String) -> Void

    var body: some View {
        CursorCompanionView(
            state:    viewModel.state,
            isPinned: $viewModel.isPinned,
            onAction: onAction,
            tailOnLeft: tailDir.tailOnLeft
        )
    }
}
