import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchManager:        NotchManager?
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        EvidenceEvaluator.runIsolationVerification()
        #endif

        // Activate once so the dock running indicator appears. Mira's panels are
        // all .nonactivatingPanel, so without this the app never enters active state
        // and the dock dot never shows despite LSUIElement = false.
        NSApp.activate(ignoringOtherApps: true)

        ScreenCaptureService.requestAccessIfNeeded()

        // Restore the signed-in session eagerly. SupabaseService.init → loadSession
        // populates the static cachedAccessToken (via the session didSet), which
        // MiraBackend and MiraState.isSignedIn read for every proxy call. Without
        // this, a restored session stays invisible until some view first touches
        // SupabaseService.shared, so proxy calls fail as "not signed in" right
        // after launch. Instantiating AccountService.shared also restores authState.
        _ = AccountService.shared

        AgentProcessManager.shared.start()

        // ChimeWarmer — prime audio hardware pipeline for zero-latency first chime
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            AudioCueService.shared.warmHardware()
        }

        _ = UpdateService.shared   // starts Sparkle background update checks
        IntegrationContextService.shared.restoreFromDefaults()
        PostHogService.shared.capture("app_launched")
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

        statusBarController = StatusBarController(miraState: manager.miraState)

        // Show onboarding on first launch, after the island is ready
        if OnboardingService.shared.isFirstLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                OnboardingWindowController.shared.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentProcessManager.shared.stop()
        RealtimeVoiceService.shared.disconnectAlwaysOn()
        MiraCursorManager.shared.deactivate()
        AgentHUDWindowManager.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
