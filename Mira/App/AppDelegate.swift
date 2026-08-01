import Cocoa
import SwiftUI
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchManager:        NotchManager?
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        EvidenceEvaluator.runIsolationVerification()
        #endif

        // Regular app — shows a Dock icon, an app-switcher entry, and (the reason
        // for this) an entry in the Force Quit Applications window. macOS only lists
        // apps with the .regular activation policy there; accessory/agent apps are
        // hidden from Force Quit and the Dock. The menu-bar item + notch island + global
        // hotkeys still drive the UX; panels remain .nonactivatingPanel so we don't
        // steal focus. (LSUIElement=false in Info.plist sets this at launch; we assert
        // it here belt-and-suspenders.)
        NSApp.setActivationPolicy(.regular)

        ScreenCaptureService.requestAccessIfNeeded()

        // Restore the signed-in session eagerly. SupabaseService.init → loadSession
        // populates the static cachedAccessToken (via the session didSet), which
        // MiraBackend and MiraState.isSignedIn read for every proxy call. Without
        // this, a restored session stays invisible until some view first touches
        // SupabaseService.shared, so proxy calls fail as "not signed in" right
        // after launch. Instantiating AccountService.shared also restores authState.
        _ = AccountService.shared

        // Handle the mira:// custom URL scheme — used by the Apple web-OAuth flow,
        // which redirects back to mira://auth-callback#access_token=… on success.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID:    AEEventID(kAEGetURL))

        // Keep the access token fresh. It expires ~1h after sign-in and nothing
        // renewed it before, so all proxy AI (chat/voice/grounding) died an hour
        // later. Refresh now (covers a token that expired while the app was closed),
        // and again on every reactivation (covers the machine sleeping past expiry).
        // The pre-expiry timer in SupabaseService handles the steady-state case.
        Task { await SupabaseService.shared.ensureFreshToken() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { await SupabaseService.shared.ensureFreshToken() }
        }

        AgentProcessManager.shared.start()

        // ChimeWarmer — prime audio hardware pipeline for zero-latency first chime
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            AudioCueService.shared.warmHardware()
        }

        _ = UpdateService.shared   // starts Sparkle background update checks
        IntegrationContextService.shared.restoreFromDefaults()
        PostHogService.shared.capture("app_launched")

        // Clipboard history + text expansion + clip reminders
        ClipboardMonitorService.shared.start()
        TextExpansionService.shared.start()
        MediaKeyInterceptService.shared.start()
        _ = HUDOverlayWindowController.shared   // wires up its NotificationCenter observers
        ClipReminderService.shared.requestPermission()

        // Custom dock (restores enabled state from previous launch)
        MiraDockManager.shared.restoreIfEnabled()
        _ = AppContextService.shared       // start frontmost-app observer
        _ = SidecarSuggestionService.shared // start dwell tracker
        SkillCatalog.shared.refresh()      // seed built-in skill bundles + scan

        let manager = NotchManager()
        manager.setup()
        notchManager = manager
        CursorCompanionController.shared.start()   // honors the dock/undock preference
        AgentHUDWindowManager.shared.start()

        // Phase 0 notch modules. Registration order is the initial carousel order;
        // the user's saved order takes over once they reorder anything.
        NotchModuleRegistry.shared.register([
            DashboardModule(),
            WeatherModule(),
            MediaModule(),
            CalendarModule(),
            TodoModule(),
            NotesModule(),
            PomodoroModule(),
            SnapZoneModule(),
            DropActionsModule(),
            ShelfModule(),
            ScreenTimeModule(),
            DayProgressModule(),
            TranslationModule(),
            CodeHostingModule(),
            AICodingModule(),
            NotificationsModule(),
            BluetoothModule(),
            LiveActivitiesModule(),
            SystemModule(),
            ModuleBrowserModule()
        ])

        // Bluetooth polls independently of its module being visible, because the
        // low-battery warning it feeds into the collapsed strip is only useful if
        // it fires when you AREN'T looking at the Bluetooth panel.
        // Screen Time must run from LAUNCH, not from didAppear: usage cannot be
        // backfilled, so a minute not recorded is gone.
        ScreenTimeService.shared.start()

        BluetoothService.shared.start()

        // Keeps every Mira window out of capture, not just the island. The
        // preference has existed for a while but only one window honoured it.
        ScreenCapturePrivacyService.shared.start()

        // Meeting alerts have to be watching before you open the notch — the
        // whole point is that it interrupts you.
        MeetingAlertService.shared.start()

        // AI Coding has two halves with different costs, so they start on
        // different terms.
        //
        // The transcript watcher is the zero-setup path and runs whenever Claude
        // Code has ever been used on this Mac — it's a lazy poll over files that
        // already exist, and it has to be warm before the panel is opened or the
        // first frame shows an empty list.
        if ClaudeCodeSessionWatcher.shared.isAvailable {
            ClaudeCodeSessionWatcher.shared.start(interval: 6)
        }

        // The socket only listens once the CLI hook exists — otherwise every
        // user pays for a socket server for a feature they never set up. It also
        // has to be running before the module is opened: a permission ask
        // arrives while you're in the terminal, and the point is that the notch
        // lights up without you going looking for it.
        if AICodingHookInstaller.shared.isInstalled {
            AICodingBridgeService.shared.start()
        }

        // Snap Zones watches for window drags reaching the top of the screen.
        SnapZoneService.shared.start()

        // Notification polling runs from launch, not from the panel opening.
        // The point of the feature is that an alert pops on the CLOSED notch,
        // which is precisely when nobody has the Notifications panel open.
        SystemNotificationsService.shared.start()

        // The banner observer: catches every alert the moment it is drawn —
        // including iPhone ones, which reach no database — and hides the native
        // banner when the user has asked for that. Independent of the poll above,
        // which now only supplies history.
        NotificationBannerWatcher.shared.start()

        // Plug/unplug and low-battery notices for the collapsed notch. Started
        // before the strip so the first read establishes a baseline rather than
        // announcing "plugged in" just because the laptop is on a charger.
        PowerActivityService.shared.start()

        // Volume HUD for changes that did NOT come from the media keys —
        // Control Center, a script, a headset button.
        SystemVolumeObserver.shared.start()

        // Rotating collapsed strip. Voice/agent state preempts it in the pill.
        LiveActivityService.shared.start()

        // Notch snooze (⌃⌥Z). Instantiated so it observes the hotkey notification.
        _ = NotchSnoozeService.shared

        // Dictate-anywhere (⌃⌥S): hold-to-talk transcription into any app's focused
        // field, plus its "Dictating…" pill. Wiring only — hotkey is registered by
        // GlobalShortcutManager; these observe the began/ended notifications.
        DictationAnywhereService.shared.start()
        DictationHUDWindowManager.shared.start()

        // Start Point Follow-Up monitor if previously enabled
        if UserDefaults.standard.bool(forKey: "mira_point_follow_up_enabled") {
            PointFollowUpService.shared.start()
        }

        // Bidirectional MCP: stand up Mira's MCP server so Codex can call back into
        // Mira's tools. Only relevant when autonomous control is enabled (the only path
        // that spawns Codex). The server reconciles ~/.codex/config.toml once it binds.
        if UserDefaults.standard.bool(forKey: "mira_autonomous_enabled") {
            MiraMCPServer.shared.start()
        }

        statusBarController = StatusBarController(miraState: manager.miraState)
        MenuBarIconManager.shared.startIfEnabled()

        #if DEBUG
        // Launch-time self-test for the autonomy pipeline (router → ledger →
        // announce), gated by MIRA_SELFTEST=1 so it only runs when asked. Prints
        // runtime evidence to stdout: AX trust, route taken, ledger count.
        if ProcessInfo.processInfo.environment["MIRA_SELFTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Task { @MainActor in
                    NSLog("[selftest] AXIsProcessTrusted = \(AXIsProcessTrusted())")
                    let before = TaskRunLedger.shared.runsThisMonth
                    let outcome = ActuationRouter.shared.perform(
                        .setText("Mira self-test ✅", field: nil),
                        on: "com.apple.TextEdit")
                    NSLog("[selftest] router outcome: \(outcome.summary)")
                    await ComputerUseOrchestrator.shared.perform(
                        .setText("Mira self-test via orchestrator ✅", field: nil),
                        on: "com.apple.TextEdit",
                        taskDescription: "self-test note in TextEdit",
                        apiKey: "")
                    NSLog("[selftest] ledger runsThisMonth: \(before) -> \(TaskRunLedger.shared.runsThisMonth)")
                    NSLog("[selftest] DONE — notification should have posted + voice spoken")
                }
            }
        }
        #endif

        // Voice-driven notch onboarding on first launch — Mira speaks each step,
        // no modal window, no buttons to click.
        if OnboardingService.shared.isFirstLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NotchOnboardingManager.shared.start(with: manager.animController)
            }
        }
    }

    /// Receives mira:// URLs (Apple web-OAuth callback) and forwards the auth
    /// callback to AccountService to adopt the session.
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor,
                                      withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "mira" else { return }
        if urlString.contains("auth-callback") {
            Task { @MainActor in await AccountService.shared.handleAppleWebCallback(url) }
        } else if urlString.contains("spotify/callback") {
            Task { @MainActor in await SpotifyAuthService.shared.handleCallback(url) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentProcessManager.shared.stop()
        RealtimeVoiceService.shared.disconnectAlwaysOn()
        MiraCursorManager.shared.deactivate()
        AgentHUDWindowManager.shared.stop()
        MiraDockManager.shared.disable()   // restore native Dock autohide + killall Dock
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
