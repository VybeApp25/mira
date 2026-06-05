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

    private let taskStore:         AgentTaskStore
    private let overlay:           OverlayWindowController
    private let capture:           ScreenCaptureService
    private let voice:             VoiceService
    // App-lifetime WakeWordService — kept here so view-recreation doesn't spawn duplicate audio sessions.
    let wakeWord:                  WakeWordService
    private let hoverDetection:    HoverDetectionService
    private let tooltipController: HoverTooltipController
    private var insightManager:    HoverInsightManager?
    private let shortcutManager =  GlobalShortcutManager()
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
        overlay           = OverlayWindowController()
        capture           = ScreenCaptureService()
        voice             = VoiceService()
        wakeWord          = WakeWordService()
        hoverDetection    = HoverDetectionService()
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
            wakeWord:       wakeWord,
            geometry:       geometry
        )
        windowManager.install(rootView: island)
        insightManager = HoverInsightManager(
            miraState:      miraState,
            animController: animController,
            capture:        capture,
            tooltip:        tooltipController
        )
        wakeWord.start()
        shortcutManager.start()
        BackgroundScheduler.shared.start()
        wireHover()
        wireHoverDetection()
        wireShortcutUpdates()
        // Expand island when a shortcut fires via StatusBarController's menu key equivalents
        NotificationCenter.default.addObserver(forName: .miraActivateVoice, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let alreadyExpanded = self.animController.state == .expanded
            self.expandForShortcut()
            if !alreadyExpanded {
                // IslandChatView is inside `if isExpanded` — it wasn't in the hierarchy yet.
                // Re-post after SwiftUI renders expandedContent so the view catches the notification.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    NotificationCenter.default.post(name: .miraActivateVoice, object: nil)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: .miraActivateText, object: nil, queue: .main) { [weak self] _ in
            self?.expandForShortcut()
        }
    }

    private func expandForShortcut() {
        collapseWork?.cancel()
        collapseWork = nil
        wakeWordRestartWork?.cancel()
        wakeWordRestartWork = nil
        insightManager?.cancel()
        windowManager.setInteractive(true)
        animController.expand()
        hoverManager.update(activationRect: expandedZone())
        hoverDetection.pause()
        tooltipController.hide()
        wakeWord.pause()
    }

    // MARK: - Hover wiring

    // Pending collapse work item — cancelled if the cursor re-enters before it fires.
    private var collapseWork:       DispatchWorkItem?
    // Pending wakeWord restart — cancelled on re-enter so wake word never restarts while island is open.
    private var wakeWordRestartWork: DispatchWorkItem?

    private func wireHover() {
        hoverManager.update(activationRect: collapsedZone())

        hoverManager.onEnter = { [weak self] in
            guard let self else { return }
            collapseWork?.cancel()
            collapseWork = nil
            wakeWordRestartWork?.cancel()
            wakeWordRestartWork = nil
            // Clear any ambient hover summary — user is now actively using the island.
            insightManager?.cancel()
            windowManager.setInteractive(true)
            animController.expand()
            hoverManager.update(activationRect: expandedZone())
            hoverDetection.pause()
            tooltipController.hide()
            wakeWord.pause()
        }

        hoverManager.onExit = { [weak self] in
            guard let self else { return }
            hoverManager.update(activationRect: collapsedZone())
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                animController.collapse()
                let restartWork = DispatchWorkItem { [weak self] in
                    self?.windowManager.setInteractive(false)
                    self?.hoverDetection.resume()
                    self?.wakeWord.start()
                }
                wakeWordRestartWork = restartWork
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: restartWork)
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        hoverManager.start(activationRect: collapsedZone())
    }

    private func wireShortcutUpdates() {
        NotificationCenter.default.addObserver(
            forName: .miraShortcutsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.shortcutManager.update() }
    }

    private func wireHoverDetection() {
        hoverDetection.onDwell = { [weak self] pos, optionHeld in
            guard let self else { return }
            insightManager?.handleDwell(at: pos, optionHeld: optionHeld)
        }
        hoverDetection.start()

        NotificationCenter.default.addObserver(
            forName: .miraScreenCompanionChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if !HoverPreferences.shared.screenCompanionEnabled {
                tooltipController.hide()
                insightManager?.cancel()
            }
        }
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
