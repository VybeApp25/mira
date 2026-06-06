import ScreenCaptureKit
import AppKit

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
    // Resets on restart since this is not persisted.
    private static var permissionDenied = false

    // Captured once at launch so evaluateState() can classify identity-mismatch
    // vs genuine-denial without re-querying at every capture site.
    private static var preflightGranted = false

    // MARK: - SCK error mapping

    /// Maps a raw SCK NSError to the normalized CapabilityError type.
    /// Keeps SCK-specific error codes (domain string, -3801) local to this service.
    private static func capabilityError(from error: NSError) -> CapabilityError {
        guard error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
              error.code  == -3801 else { return .other(error) }
        return .notAuthorized
    }

    // MARK: - Launch

    /// Call once at launch. Only prompts if permission hasn't been granted yet.
    static func requestAccessIfNeeded() {
        guard !permissionDenied else { return }
        preflightGranted = CGPreflightScreenCaptureAccess()
        guard !preflightGranted else {
            #if DEBUG
            print("[ScreenCapture] TCC preflight: granted — identity: \(Bundle.main.executablePath ?? "unknown")")
            #endif
            return
        }
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Capture

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

        } catch let error as NSError {
            let state = evaluateCapabilityState(
                preflight:    Self.preflightGranted,
                runtimeError: Self.capabilityError(from: error)
            )
            switch state {
            case .available:
                throw MiraError.api("Screen capture failed: \(error.localizedDescription)")
            case .identityMismatch, .denied:
                Self.permissionDenied = true
                // Re-prompt regardless of cause: opens the permission dialog or the
                // "open System Settings" banner for the currently-running binary.
                CGRequestScreenCaptureAccess()
                let message: String = state == .identityMismatch
                    ? "Screen Recording is granted to a different version of Mira. Re-approve this version in System Settings › Privacy & Security › Screen Recording, then relaunch."
                    : "Screen Recording permission required. Grant access in System Settings › Privacy & Security › Screen Recording, then relaunch Mira."
                throw MiraError.api(message)
            }
        }
    }
}
