import ScreenCaptureKit
import AppKit

class ScreenCaptureService {

    // Set to true after the first TCC denial so we stop spamming the permission dialog.
    private static var permissionDenied = false

    /// Call once at launch. Only prompts if permission hasn't been decided yet.
    static func requestAccessIfNeeded() {
        guard !permissionDenied else { return }
        CGRequestScreenCaptureAccess()
    }

    func captureMainDisplay() async throws -> NSImage {
        guard !Self.permissionDenied else {
            throw MiraError.api("Screen Recording permission denied.")
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let display = content.displays.first else {
                throw MiraError.api("No display available")
            }

            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.captureResolution = .best
            config.showsCursor = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            return NSImage(cgImage: cgImage, size: CGSize(width: display.width, height: display.height))

        } catch let error as NSError where error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && error.code == -3801 {
            // TCC denied — latch the flag so we never call SCK again until the app restarts.
            Self.permissionDenied = true
            throw MiraError.api("Screen Recording permission denied. Enable Mira in System Settings › Privacy & Security › Screen Recording, then relaunch.")
        }
    }
}
