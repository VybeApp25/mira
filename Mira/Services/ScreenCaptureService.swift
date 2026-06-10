import ScreenCaptureKit
import AppKit

// MARK: - Multi-display capture

/// A single captured display — mirrors Clicky's CompanionScreenCapture.
struct MiraScreenCapture {
    let imageData:            Data
    let label:                String
    let isCursorScreen:       Bool
    let displayFrame:         CGRect   // AppKit coords (bottom-left origin)
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
}

// MARK: - Capability pipeline types

/// Normalized OS-level denial signal, independent of the specific framework.
///
/// Each permission domain maps its own error type to this:
///   Screen capture  → SCStreamErrorDomain -3801
///   Microphone      → AVAuthorizationStatus.denied
///   Accessibility   → AXError / kAXErrorNotImplemented
///   Automation      → NSCocoaErrorDomain -600
///
/// evaluateState() accepts this type so the classification logic never
/// imports framework-specific error codes. The mapping stays local to
/// each service (ScreenCaptureService, future MicService, etc.).
enum CapabilityError {
    /// The runtime API reported that access was not authorized.
    case notAuthorized
    /// Some other error unrelated to authorization.
    case other(Error)
}

/// Typed result of evaluating a macOS TCC capability at runtime.
///
/// macOS permissions are not boolean — they are identity-scoped capabilities.
/// TCC binds each grant to a (bundle-id, code-signing-identity) tuple, so the
/// same app can appear "granted" in System Settings while a different build of
/// that app has no grant at all. This enum makes that distinction explicit.
///
/// All permission domains (screen, mic, accessibility, automation) produce
/// this type from their own `evaluateState(preflight:runtimeError:)` calls
/// so every capability decision follows the same classification model.
enum CapabilityState {
    /// Permission granted and runtime call succeeded — capability is usable.
    case available
    /// TCC preflight said granted, but runtime call failed with notAuthorized.
    /// The grant belongs to a different code-signing identity (e.g. a prior build).
    /// Remediation: re-approve this binary in System Settings, then relaunch.
    case identityMismatch
    /// TCC preflight said not granted. Remediation: grant in System Settings.
    case denied
}

/// Pure classification function — no OS calls, no side effects.
/// Inputs: the two normalized signals any permission domain can provide.
/// Output: a domain-level capability state safe to switch on for UI + remediation.
func evaluateCapabilityState(preflight: Bool, runtimeError: CapabilityError?) -> CapabilityState {
    guard let error = runtimeError else { return .available }
    if case .other = error { return .available }          // non-auth error — treat as available
    return preflight ? .identityMismatch : .denied
}

// MARK: - Screen capture

class ScreenCaptureService {

    // True after the first SCK -3801 so we stop queuing capture work until relaunch.
    private static var permissionDenied = false

    // Captured once at launch so evaluateState() can classify identity-mismatch.
    private static var preflightGranted = false

    // Persists last-confirmed grant across sessions. CGPreflightScreenCaptureAccess()
    // can return false-negatives on macOS Sequoia even when permission is granted;
    // this key prevents unnecessarily blocking captures when that happens.
    // Adapted from farzaa/clicky (MIT).
    private static let hasPreviouslyGrantedKey = "com.mira.hasPreviouslyConfirmedScreenRecording"

    static var hasPreviouslyConfirmedScreenRecording: Bool {
        get { UserDefaults.standard.bool(forKey: hasPreviouslyGrantedKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasPreviouslyGrantedKey) }
    }

    // Returns true when we should proceed without re-prompting. Falls back to
    // the last known granted state to handle CGPreflightScreenCaptureAccess() false-negatives.
    static var shouldTreatAsGranted: Bool {
        let now = CGPreflightScreenCaptureAccess()
        if now { hasPreviouslyConfirmedScreenRecording = true }
        return now || hasPreviouslyConfirmedScreenRecording
    }

    // MARK: - SCK error mapping

    /// Maps a raw SCK NSError to the normalized CapabilityError type.
    /// Keeps SCK-specific error codes (domain string, -3801) local to this service.
    private static func capabilityError(from error: NSError) -> CapabilityError {
        guard error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
              error.code  == -3801 else { return .other(error) }
        return .notAuthorized
    }

    // MARK: - Launch

    /// Call once at launch. Records preflight state; does NOT prompt —
    /// SCK itself handles the permission request on first capture attempt.
    /// Calling CGRequestScreenCaptureAccess() at launch is unreliable on
    /// macOS Sequoia and causes a confusing prompt loop when permission
    /// is already granted to a prior build.
    static func requestAccessIfNeeded() {
        guard !permissionDenied else { return }
        // CGPreflightScreenCaptureAccess is unreliable on Sequoia — it can
        // return false even when permission IS granted. We record it for
        // classification purposes only; we do not use it as a gate.
        preflightGranted = CGPreflightScreenCaptureAccess()
        #if DEBUG
        print("[ScreenCapture] TCC preflight: \(preflightGranted) — identity: \(Bundle.main.executablePath ?? "unknown")")
        #endif
    }

    // MARK: - Capture

    func captureMainDisplay() async throws -> NSImage {
        // Reset permissionDenied so a new attempt can succeed after the user
        // grants/re-grants permission in System Settings. Without this, one
        // failed attempt permanently blocks all subsequent captures this session.
        if Self.permissionDenied {
            Self.permissionDenied = false
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

            // Exclude Mira's own windows so the model sees the user's screen, not our panel.
            let miraWindows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let filter = SCContentFilter(display: display, excludingWindows: miraWindows)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            return NSImage(cgImage: cgImage, size: CGSize(width: display.width, height: display.height))

        } catch let error as NSError {
            let state = evaluateCapabilityState(
                preflight:    Self.preflightGranted,
                runtimeError: Self.capabilityError(from: error)
            )
            switch state {
            case .available:
                throw MiraError.api("Screen capture failed: \(error.localizedDescription)")
            case .identityMismatch:
                Self.permissionDenied = true
                throw MiraError.api("Screen Recording is on but was approved for a different version of Mira. In System Settings → Privacy & Security → Screen Recording, remove Mira and add it again, then relaunch.")
            case .denied:
                Self.permissionDenied = true
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                throw MiraError.api("Screen Recording permission required. Grant access in System Settings → Privacy & Security → Screen Recording, then relaunch Mira.")
            }
        }
    }

    // MARK: - Multi-display capture (ported from farzaa/clicky, MIT)

    /// Captures all connected displays as JPEG, labeling each with cursor proximity.
    /// The cursor screen is always first. Own-app windows are excluded so the AI
    /// sees only the user's content.
    static func captureAllDisplaysAsJPEG() async throws -> [MiraScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else {
            throw MiraError.api("No display available for capture")
        }

        let mouseLocation = NSEvent.mouseLocation
        let ownBundle = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundle }

        // Build displayID → NSScreen map so we use AppKit coords (bottom-left origin)
        // which match NSEvent.mouseLocation. SCDisplay.frame uses CG coords (top-left).
        var screenByID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                screenByID[id] = screen
            }
        }

        let sorted = content.displays.sorted { a, b in
            let fa = screenByID[a.displayID]?.frame ?? a.frame
            let fb = screenByID[b.displayID]?.frame ?? b.frame
            let ac = fa.contains(mouseLocation)
            let bc = fb.contains(mouseLocation)
            if ac != bc { return ac }
            return false
        }

        var results: [MiraScreenCapture] = []
        let total = sorted.count

        for (idx, display) in sorted.enumerated() {
            let displayFrame = screenByID[display.displayID]?.frame
                ?? CGRect(x: display.frame.minX, y: display.frame.minY,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursor = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let cfg    = SCStreamConfiguration()
            let maxDim = 1280
            let ratio  = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                cfg.width  = maxDim
                cfg.height = Int(CGFloat(maxDim) / ratio)
            } else {
                cfg.height = maxDim
                cfg.width  = Int(CGFloat(maxDim) * ratio)
            }

            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)

            guard let jpeg = NSBitmapImageRep(cgImage: cg)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { continue }

            let label: String
            if total == 1 {
                label = "user's screen (cursor is here)"
            } else if isCursor {
                label = "screen \(idx + 1) of \(total) — cursor is here (primary)"
            } else {
                label = "screen \(idx + 1) of \(total) — secondary screen"
            }

            results.append(MiraScreenCapture(
                imageData:             jpeg,
                label:                 label,
                isCursorScreen:        isCursor,
                displayFrame:          displayFrame,
                displayWidthInPoints:  Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height)
            ))
        }

        guard !results.isEmpty else { throw MiraError.api("Failed to capture any screen") }
        return results
    }
}
