import ScreenCaptureKit
import AppKit

class ScreenCaptureService {

    /// Returns true if Screen Recording is already granted — does NOT prompt.
    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Prompts the user to grant Screen Recording in System Settings if not already granted.
    static func requestAccessIfNeeded() {
        guard !hasAccess else { return }
        CGRequestScreenCaptureAccess()
    }

    func captureMainDisplay() async throws -> NSImage {
        guard Self.hasAccess else {
            throw MiraError.api("Screen Recording permission not granted. Enable it in System Settings › Privacy & Security.")
        }
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
    }
}
