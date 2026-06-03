import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchManager:        NotchManager?
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let manager = NotchManager()
        manager.setup()
        notchManager = manager

        // Status bar item: secondary access point for settings / quick chat.
        statusBarController = StatusBarController(miraState: manager.miraState)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
