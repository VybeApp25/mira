import ScreenCaptureKit
import AppKit

class ScreenCaptureService {

    // True after the first SCK -3801 so we stop queuing capture work until relaunch.
    // Reset happens automatically on restart since this is not persisted.
    private static var permissionDenied = false

    // Whether CGPreflight said "granted" at launch time. Used to distinguish
    // "genuinely not granted" from "granted to a different code-signing identity".
    private static var preflightGranted = false

    /// Call once at launch. Only prompts if permission hasn't been granted yet.
    static func requestAccessIfNeeded() {
        guard !permissionDenied else { return }
        preflightGranted = CGPreflightScreenCaptureAccess()
        guard !preflightGranted else {
            #if DEBUG
            // TCC says granted. Log the executable identity so any future
            // "permission OK but capture fails" mismatch is immediately traceable.
            print("[ScreenCapture] TCC preflight: granted — identity: \(Bundle.main.executablePath ?? "unknown")")
            #endif
            return
        }
        CGRequestScreenCaptureAccess()
    }

    func captureMainDisplay() async throws -> NSImage {
        guard !Self.permissionDenied else {
            throw MiraError.api("Screen Recording permission denied.")
        }

        do {
            #if DEBUG
            print("[ScreenCapture] SCK session starting — identity: \(Bundle.main.executablePath ?? "unknown")")
            #endif

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
            // SCK -3801: not authorized for this binary's signing identity.
            //
            // Two distinct causes, distinguishable by preflightGranted:
            //  • preflightGranted = true  → TCC has an entry for a *different* identity
            //    (e.g. app was replaced by a new build with a new ad-hoc signature).
            //    The old entry appears "granted" in System Settings but is bound to the
            //    old binary — this running binary has no entry.
            //  • preflightGranted = false → permission was genuinely never granted.
            //
            // CGRequestScreenCaptureAccess() is correct in both cases: it opens the
            // System Settings prompt (not-decided) or the "open System Settings" banner
            // (decided but stale), surfacing the right action to the user.
            Self.permissionDenied = true
            CGRequestScreenCaptureAccess()

            let message = Self.preflightGranted
                ? "Screen Recording is granted to a different version of Mira. Re-approve this version in System Settings › Privacy & Security › Screen Recording, then relaunch."
                : "Screen Recording permission required. Grant access in System Settings › Privacy & Security › Screen Recording, then relaunch Mira."
            throw MiraError.api(message)
        }
    }
}
