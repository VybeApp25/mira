import AppKit

/// Top-level orchestrator: wires geometry → window → hover → animation.
@MainActor
final class NotchManager {

    // Exposed so AppDelegate can share instances with the status-bar controller.
    let miraState: MiraState
    let animController: AnimationController

    private let geometry:      NotchGeometry
    private let windowManager: MiraIslandWindowManager
    private let hoverManager:  HoverTrackingManager

    private let taskStore:        AgentTaskStore
    private let overlay:          OverlayWindowController
    private let capture:          ScreenCaptureService
    private let voice:            VoiceService
    private let hoverSummary:     HoverSummaryService
    private let tooltipController: HoverTooltipController
    // Shortcuts are handled via NSMenu key equivalents in StatusBarController
    // (no Accessibility permission needed that way)

    init() {
        let geo        = NotchGeometryProvider.detect()
        geometry       = geo
        let state      = MiraState()
        miraState      = state
        animController = AnimationController(geometry: geo)
        windowManager  = MiraIslandWindowManager(geometry: geo)
        hoverManager   = HoverTrackingManager()
        taskStore      = AgentTaskStore.shared
        overlay        = OverlayWindowController()
        capture        = ScreenCaptureService()
        voice          = VoiceService()
        hoverSummary   = HoverSummaryService(apiKey: { state.effectiveAPIKey })
        tooltipController = HoverTooltipController()
    }

    func setup() {
        // Debug: log detected geometry at launch
        let g = geometry
        NSLog("[Mira] hasNotch=%@ notchW=%.1f notchH=%.1f centerX=%.1f centerY=%.1f screen=%.0fx%.0f",
              g.hasNotch ? "YES" : "NO",
              g.notchWidth, g.notchHeight,
              g.notchCenter.x, g.notchCenter.y,
              g.screen.frame.width, g.screen.frame.height)
        NSLog("[Mira] safeAreaInsets.top=%.1f",
              g.screen.safeAreaInsets.top)
        NSLog("[Mira] windowFrame x=%.1f y=%.1f w=%.0f h=%.0f",
              g.screen.frame.midX - MiraIslandWindowManager.windowW / 2,
              g.screen.frame.maxY - MiraIslandWindowManager.windowH,
              MiraIslandWindowManager.windowW,
              MiraIslandWindowManager.windowH)

        let island = MiraIslandView(
            animController: animController,
            miraState:      miraState,
            taskStore:      taskStore,
            overlay:        overlay,
            capture:        capture,
            voice:          voice,
            geometry:       geometry
        )
        windowManager.install(rootView: island)
        wireHover()
        wireHoverSummary()
        // Expand island when a shortcut fires via StatusBarController's menu key equivalents
        NotificationCenter.default.addObserver(forName: .miraActivateVoice, object: nil, queue: .main) { [weak self] _ in
            self?.expandForShortcut()
        }
        NotificationCenter.default.addObserver(forName: .miraActivateText, object: nil, queue: .main) { [weak self] _ in
            self?.expandForShortcut()
        }
    }

    private func expandForShortcut() {
        collapseWork?.cancel()
        collapseWork = nil
        windowManager.setInteractive(true)
        animController.expand()
        hoverManager.update(activationRect: expandedZone())
        // Voice always wins — dismiss any visible tooltip and suspend hover detection.
        hoverSummary.isEnabled = false
        tooltipController.hide()
    }

    // MARK: - Hover wiring

    // Pending collapse work item — cancelled if the cursor re-enters before it fires.
    private var collapseWork: DispatchWorkItem?

    private func wireHover() {
        hoverManager.update(activationRect: collapsedZone())

        hoverManager.onEnter = { [weak self] in
            guard let self else { return }
            // Cancel any pending collapse so a brief cursor exit doesn't flicker.
            collapseWork?.cancel()
            collapseWork = nil
            windowManager.setInteractive(true)
            animController.expand()
            // Widen tracking zone to cover the full expanded panel.
            hoverManager.update(activationRect: expandedZone())
            // Suppress hover summaries while the island is open.
            hoverSummary.isEnabled = false
            tooltipController.hide()
        }

        hoverManager.onExit = { [weak self] in
            guard let self else { return }
            // Shrink zone immediately so re-entry detection snaps back to notch area.
            hoverManager.update(activationRect: collapsedZone())
            // Debounce collapse — ignore exits shorter than 120 ms (cursor wobble).
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                animController.collapse()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    self?.windowManager.setInteractive(false)
                    self?.hoverSummary.isEnabled = true
                }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        hoverManager.start(activationRect: collapsedZone())
    }

    private func wireHoverSummary() {
        hoverSummary.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .summary(let text, let pos):
                tooltipController.show(text: text, near: pos)
            case .explainStart(let pos):
                tooltipController.showLoading(near: pos)
            case .explain(let text, let pos):
                tooltipController.show(text: text, near: pos, isExplanation: true)
            }
        }
        hoverSummary.start()
    }

    /// Small zone around the notch — triggers open when cursor enters.
    private func collapsedZone() -> CGRect {
        let pad: CGFloat = 50
        let nc = geometry.notchCenter
        return CGRect(
            x:      nc.x - geometry.notchWidth / 2 - pad,
            y:      nc.y - pad,
            width:  geometry.notchWidth + pad * 2,
            height: geometry.notchHeight + pad * 2
        )
    }

    /// Full expanded panel + padding — keeps the island open while user interacts.
    private func expandedZone() -> CGRect {
        let pad: CGFloat = 20
        let s   = geometry.screen
        let w   = AnimationController.expandedW + pad * 2
        let h   = AnimationController.expandedH + geometry.notchHeight + pad
        return CGRect(
            x:      s.frame.midX - w / 2,
            y:      s.frame.maxY - h,
            width:  w,
            height: h
        )
    }
}
