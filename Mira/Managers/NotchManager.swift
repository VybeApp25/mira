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
    private let dropZone:      NotchDropZoneController

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
        dropZone       = NotchDropZoneController(geometry: geo, animController: animController)
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
        dropZone.install()
        insightManager = HoverInsightManager(
            miraState:      miraState,
            animController: animController,
            capture:        capture,
            tooltip:        tooltipController
        )
        // Pure PTT mode — no persistent session. The WebSocket opens on key-down and
        // closes after the response finishes speaking (mirrors HeyClicky's PTT behavior).
        // WakeWord runs as the ambient fallback when no PTT session is active.
        wakeWord.start()
        shortcutManager.start()
        BackgroundScheduler.shared.start()
        // Pre-warm the Realtime WebSocket so the first PTT is instant.
        // Mirrors HeyClicky's keep-warm behavior — session is healthy before the user speaks.
        RealtimeVoiceService.shared.prewarm()
        // Restore always-on voice if it was active before the last quit.
        if UserDefaults.standard.bool(forKey: "mira_always_on") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                RealtimeVoiceService.shared.connectAlwaysOn()
                NSLog("[Mira] always-on voice restored from previous session")
            }
        }
        Task { await QuotaService.shared.refreshQuota() }
        MiraState.shared = miraState
        CronScheduler.shared.start()
        CallHUDManager.shared.start()   // meeting-assistant: watch for calls, offer transcription
        RadialLauncherModel.shared.startTrackingRecents()   // radial launcher: track recent apps
        RadialLauncherHotkey.shared.start()                 // radial launcher: Option-tap toggle
        ExternalTriggerRunner.shared.rebuildWatchers()
        _ = CursorCompanionManager.shared   // initialize ambient presence layer
        _ = CursorBubbleService.shared      // cursor speech bubble (lazy init)
        _ = ResponseCardService.shared      // artifact card overlay (lazy init)
        FloatingButtonService.shared.start(animController: animController, miraState: miraState)
        wireHover()
        wireHoverDetection()
        wireShortcutUpdates()
        // Expand island when a shortcut fires via StatusBarController's menu key equivalents
        // All observers use queue: .main, so MainActor.assumeIsolated is sound —
        // it gives the closures static MainActor isolation instead of crossing
        // the actor boundary unchecked.
        // Voice shortcut — PTT runs in the closed notch pill. The pill shows listening/
        // thinking/speaking via SharedStatusView. The island only opens when the user
        // hovers the notch. No expand on key-down.
        // IslandChatView observes .miraActivateVoice directly and handles it when
        // already in the hierarchy (island expanded by hover before/during PTT).
        NotificationCenter.default.addObserver(forName: .miraActivateVoice, object: nil, queue: .main) { _ in
            // intentionally no-op — mic capture is driven by .miraPushToTalkBegan; island stays closed
            NSLog("[Mira] miraActivateVoice received — NOT expanding (closed-notch PTT)")
        }
        NotificationCenter.default.addObserver(forName: .miraActivateText, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.expandForShortcut() }
        }
        // A file drag entered the notch drop zone — open the island straight to
        // the Shelf tab so the user can see where the file is about to land.
        // queue: nil + DispatchQueue.main.async (not .main OperationQueue) so this
        // still fires while AppKit is running its drag-tracking run loop mode.
        NotificationCenter.default.addObserver(forName: .miraDragEnteredNotch, object: nil, queue: nil) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MiraDebugLog.log("[NotchManager] miraDragEnteredNotch → expand + Shelf tab")
                    self?.expandForShortcut()
                    NotificationCenter.default.post(name: .miraTabSelected, object: IslandTab.shelf)
                }
            }
        }

        // PTT — stays in the closed notch. Pause hover detection so dwell-triggered
        // insights can't auto-expand the island while the user is speaking.
        NotificationCenter.default.addObserver(forName: .miraPushToTalkBegan, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pttActive = true
                self?.insightManager?.cancel()
                self?.hoverDetection.pause()
                RealtimeVoiceService.shared.beginPushToTalk()
                NSLog("[Mira] PTT began — hover expand suppressed")
            }
        }
        NotificationCenter.default.addObserver(forName: .miraPushToTalkEnded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pttActive = false
                RealtimeVoiceService.shared.endPushToTalk()
                if self?.animController.state == .collapsed {
                    self?.hoverDetection.resume()
                }
                NSLog("[Mira] PTT ended — hover expand re-enabled")
            }
        }
        // Draw-on-screen spatial context (⌃⌥D) — toggle the freehand draw overlay
        NotificationCenter.default.addObserver(forName: .miraDrawModeToggled, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenDrawController.shared.toggleStandalone() }
        }
        // Notch onboarding — expand the island and make it interactive so the flow can run.
        NotificationCenter.default.addObserver(forName: .miraOnboardingStarted, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.expandForShortcut() }
        }
        NotificationCenter.default.addObserver(forName: .miraShowClipboard, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ClipboardHistoryPanel.shared.toggle() }
        }
        // Auto-collapse requested (post-PTT or post-text-response dismiss)
        NotificationCenter.default.addObserver(forName: .miraRequestCollapse, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.animController.collapse() }
        }
        // Tab switched to one with a different panel height — refresh the hover zone
        NotificationCenter.default.addObserver(forName: .miraIslandHeightChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.animController.state == .expanded else { return }
                self.hoverManager.update(activationRect: self.expandedZone())
            }
        }
        // Pin/unpin the island open for multi-step flows (e.g. Knowledge Import).
        // Reference-counted so nested/overlapping pins don't unpin prematurely.
        // IMPORTANT: queue:nil + DispatchQueue.main.async (not OperationQueue.main) so the
        // handler fires even while NSMenu is running its event-tracking run loop.
        // OperationQueue.main is blocked during NSEventTrackingRunLoopMode; GCD is not.
        NotificationCenter.default.addObserver(forName: .miraPinIsland, object: nil, queue: nil) { [weak self] note in
            let pinned = (note.userInfo?["pinned"] as? Bool) ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if pinned {
                    self.pinCount += 1
                    // Cancel any in-flight collapse and keep the panel up.
                    self.collapseGeneration += 1
                    self.collapseWork?.cancel(); self.collapseWork = nil
                } else {
                    self.pinCount = max(0, self.pinCount - 1)
                }
            }
        }
        // Always-on toggle — tap the ∞ button in the shortcut hint row to enable/disable
        NotificationCenter.default.addObserver(forName: .miraToggleAlwaysOn, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if RealtimeVoiceService.shared.isAlwaysOnActive {
                    RealtimeVoiceService.shared.disconnectAlwaysOn()
                    UserDefaults.standard.set(false, forKey: "mira_always_on")
                    NSLog("[Mira] always-on voice disabled")
                } else {
                    // Stay in the CLOSED notch — the collapsed pill shows live
                    // listening/thinking/speaking via SharedStatusView, no panel needed.
                    RealtimeVoiceService.shared.connectAlwaysOn()
                    UserDefaults.standard.set(true, forKey: "mira_always_on")
                    self.animController.collapse()
                    NSLog("[Mira] always-on voice enabled (closed notch)")
                }
            }
        }
        // "Hey Mira" wake word toggle — the Settings switch persists
        // WakeWordService.enabledKey, then posts this. start() self-gates on the
        // preference, so we only need to (re)start when idle / tear down when off.
        NotificationCenter.default.addObserver(forName: .miraToggleWakeWord, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if WakeWordService.isEnabledPreference {
                    // Resume immediately only when idle; if the panel is open the
                    // normal collapse path restarts it (and also self-gates).
                    if self.animController.state != .expanded { self.wakeWord.start() }
                    NSLog("[Mira] wake word enabled")
                } else {
                    self.wakeWordRestartWork?.cancel()
                    self.wakeWordRestartWork = nil
                    self.wakeWord.pause()
                    NSLog("[Mira] wake word disabled")
                }
            }
        }
    }

    private func expandForShortcut() {
        NSLog("[Mira] expandForShortcut called from:\n%@", Thread.callStackSymbols.prefix(8).joined(separator: "\n"))
        collapseGeneration += 1   // invalidate any in-flight collapse retries
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
    private var collapseWork:        DispatchWorkItem?
    // Pending wakeWord restart — cancelled on re-enter so wake word never restarts while island is open.
    private var wakeWordRestartWork: DispatchWorkItem?
    // Incremented on every re-entry; lets performCollapseIfIdle detect that a newer entry occurred.
    private var collapseGeneration = 0
    // >0 while a multi-step flow has pinned the island open (see .miraPinIsland).
    // Suppresses the hover-exit auto-collapse so the user can leave Mira and return.
    private var pinCount = 0
    // True while PTT is active — suppresses hover-triggered expand so the notch
    // stays closed even if the cursor drifts near the notch while the user speaks.
    private var pttActive = false

    private func wireHover() {
        hoverManager.update(activationRect: collapsedZone())

        hoverManager.onEnter = { [weak self] in
            guard let self else { return }
            // Never expand on cursor proximity while PTT is in progress.
            guard !pttActive else {
                NSLog("[Mira] hoverManager.onEnter suppressed — PTT active")
                return
            }
            collapseGeneration += 1   // invalidate any pending collapse retries
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
            // Pinned open (e.g. Knowledge Import round-trip) — never collapse on exit.
            guard pinCount == 0 else { return }
            hoverManager.update(activationRect: collapsedZone())
            let gen = collapseGeneration
            let work = DispatchWorkItem { [weak self] in
                self?.performCollapseIfIdle(generation: gen)
            }
            collapseWork = work
            // 600ms grace period — long enough for the user to move from the nav bar
            // to a button at the bottom of the expanded panel without the island vanishing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.60, execute: work)
        }

        hoverManager.start(activationRect: collapsedZone())
    }

    /// Collapses the island after the hover-exit grace period.
    /// The panel collapses immediately regardless of loading/voice state — the collapsed
    /// pill shows the active state (thinking/speaking/listening) so the user always knows
    /// what Mira is doing. Only blocks when the user must actively respond to a pending job.
    private func performCollapseIfIdle(generation: Int) {
        guard generation == collapseGeneration else { return }   // cursor re-entered — abort
        guard pinCount == 0 else { return }                      // pinned open — abort
        let needsInput = !AgentJobStore.shared.confirmationPendingJobs.isEmpty ||
                         !AgentJobStore.shared.waitingForInputJobs.isEmpty
        guard !needsInput else {
            // User needs to answer before the panel can close — retry shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) { [weak self] in
                self?.performCollapseIfIdle(generation: generation)
            }
            return
        }
        animController.collapse()
        let restartWork = DispatchWorkItem { [weak self] in
            self?.windowManager.setInteractive(false)
            self?.hoverDetection.resume()
            self?.wakeWord.start()
        }
        wakeWordRestartWork = restartWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: restartWork)
    }

    private func wireShortcutUpdates() {
        NotificationCenter.default.addObserver(
            forName: .miraShortcutsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shortcutManager.update() }
        }
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
            MainActor.assumeIsolated {
                guard let self else { return }
                if !HoverPreferences.shared.screenCompanionEnabled {
                    self.tooltipController.hide()
                    self.insightManager?.cancel()
                }
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

    /// Full expanded panel + generous padding — keeps the island open while user
    /// interacts with buttons anywhere in the panel, including at the bottom edge.
    private func expandedZone() -> CGRect {
        let padH: CGFloat = 60   // horizontal slop
        let padV: CGFloat = 50   // vertical below the panel bottom
        let s = geometry.screen
        let w = AnimationController.expandedW + padH * 2
        let h = animController.currentExpandedH + geometry.notchHeight + padV
        return CGRect(
            x:      s.frame.midX - w / 2,
            y:      s.frame.maxY - h,
            width:  w,
            height: h
        )
    }
}
