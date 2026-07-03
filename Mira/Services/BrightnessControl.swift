import CoreGraphics
import Foundation

// MARK: - BrightnessControl
//
// Real display-brightness read/write for the custom brightness HUD.
//
// Why not AppleScript: `tell application "System Events" to set brightness of
// display 1 to x` is unreliable on modern macOS — it silently does nothing on
// Apple Silicon / built-in panels — which is why Mira's brightness keys appeared
// dead and never matched the real level.
//
// Instead we call the same private APIs the OS itself uses, loaded via dlopen
// (same technique as NowPlayingService's MediaRemote):
//   • DisplayServices.framework — DisplayServicesGet/SetBrightness (built-in +
//     most external displays)
//   • CoreDisplay.framework — CoreDisplay_Display_GetUserBrightness /
//     SetUserBrightness (fallback)
// Reads are used to keep the HUD synced to the actual level rather than guessing.
enum BrightnessControl {

    // DisplayServicesGetBrightness(CGDirectDisplayID, float*) -> Int32
    private typealias DSGetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    // DisplayServicesSetBrightness(CGDirectDisplayID, float) -> Int32
    private typealias DSSetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    // CoreDisplay_Display_GetUserBrightness(CGDirectDisplayID) -> Double
    private typealias CDGetFn = @convention(c) (CGDirectDisplayID) -> Double
    // CoreDisplay_Display_SetUserBrightness(CGDirectDisplayID, Double)
    private typealias CDSetFn = @convention(c) (CGDirectDisplayID, Double) -> Void

    private static let fns: (dsGet: DSGetFn?, dsSet: DSSetFn?, cdGet: CDGetFn?, cdSet: CDSetFn?) = {
        var dsGet: DSGetFn?; var dsSet: DSSetFn?; var cdGet: CDGetFn?; var cdSet: CDSetFn?
        if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) {
            if let s = dlsym(h, "DisplayServicesGetBrightness") { dsGet = unsafeBitCast(s, to: DSGetFn.self) }
            if let s = dlsym(h, "DisplayServicesSetBrightness") { dsSet = unsafeBitCast(s, to: DSSetFn.self) }
        }
        if let h = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW) {
            if let s = dlsym(h, "CoreDisplay_Display_GetUserBrightness") { cdGet = unsafeBitCast(s, to: CDGetFn.self) }
            if let s = dlsym(h, "CoreDisplay_Display_SetUserBrightness") { cdSet = unsafeBitCast(s, to: CDSetFn.self) }
        }
        return (dsGet, dsSet, cdGet, cdSet)
    }()

    /// True when a working backend was found (so callers can fall back gracefully).
    static var isAvailable: Bool { fns.dsSet != nil || fns.cdSet != nil }

    private static var mainDisplay: CGDirectDisplayID { CGMainDisplayID() }

    /// Current brightness of the main display, 0…1. Returns nil if it can't be read.
    static func currentBrightness() -> Float? {
        let display = mainDisplay
        if let get = fns.dsGet {
            var level: Float = 0
            if get(display, &level) == 0, level >= 0, level <= 1 { return level }
        }
        if let get = fns.cdGet {
            let level = get(display)
            if level >= 0, level <= 1 { return Float(level) }
        }
        return nil
    }

    /// Sets the main display's brightness (clamped 0…1). Returns true on success.
    @discardableResult
    static func setBrightness(_ level: Float) -> Bool {
        let clamped = max(0, min(1, level))
        let display = mainDisplay
        if let set = fns.dsSet, set(display, clamped) == 0 { return true }
        if let set = fns.cdSet { set(display, Double(clamped)); return true }
        return false
    }
}
