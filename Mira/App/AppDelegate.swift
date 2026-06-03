import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var notchHUD: NotchHUDController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Notch HUD — primary UI on MacBook Pro with notch
        let hud = NotchHUDController()
        hud.setup()
        self.notchHUD = hud

        // Status bar fallback — keeps the eye icon for older Macs / external monitors
        // Shares the same MiraState so settings are synced
        statusBarController = StatusBarController(miraState: hud.miraState)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
