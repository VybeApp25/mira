import Cocoa

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
        AgentProcessManager.shared.start()

        let manager = NotchManager()
        manager.setup()
        notchManager = manager
        MiraCursorManager.shared.activate()

        statusBarController = StatusBarController(miraState: manager.miraState)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentProcessManager.shared.stop()
        MiraCursorManager.shared.deactivate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
