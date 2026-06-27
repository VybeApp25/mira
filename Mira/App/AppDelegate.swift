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

        // Menu-bar (accessory) app — no Dock icon or app-switcher entry, ambient like
        // HeyClicky. Mira's UI is the menu-bar item + the notch island + global
        // hotkeys; panels are .nonactivatingPanel so we never steal the user's focus.
        // (LSUIElement=true sets this at launch; we assert it here belt-and-suspenders.)
        NSApp.setActivationPolicy(.accessory)

        ScreenCaptureService.requestAccessIfNeeded()

        // Restore the signed-in session eagerly. SupabaseService.init → loadSession
        // populates the static cachedAccessToken (via the session didSet), which
        // MiraBackend and MiraState.isSignedIn read for every proxy call. Without
        // this, a restored session stays invisible until some view first touches
        // SupabaseService.shared, so proxy calls fail as "not signed in" right
        // after launch. Instantiating AccountService.shared also restores authState.
        _ = AccountService.shared

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
        ClipReminderService.shared.requestPermission()

        // Custom dock (restores enabled state from previous launch)
        MiraDockManager.shared.restoreIfEnabled()
        _ = AppContextService.shared       // start frontmost-app observer
        _ = SidecarSuggestionService.shared // start dwell tracker
        SkillCatalog.shared.refresh()      // seed built-in skill bundles + scan

        let manager = NotchManager()
        manager.setup()
        notchManager = manager
        MiraCursorManager.shared.activate()
        AgentHUDWindowManager.shared.start()

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

    func applicationWillTerminate(_ notification: Notification) {
        AgentProcessManager.shared.stop()
        RealtimeVoiceService.shared.disconnectAlwaysOn()
        MiraCursorManager.shared.deactivate()
        AgentHUDWindowManager.shared.stop()
        MiraDockManager.shared.disable()   // restore native Dock autohide + killall Dock
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
