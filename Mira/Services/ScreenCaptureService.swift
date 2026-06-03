import ScreenCaptureKit
import AppKit

class ScreenCaptureService {
    func captureMainDisplay() async throws -> NSImage {
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
