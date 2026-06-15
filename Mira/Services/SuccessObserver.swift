import AppKit

// MARK: - Success Observer (Teaching System M2)
//
// Reads real system/app state to decide whether a step's observable success
// check is satisfied. This is the honesty core of the teaching engine: a step
// only advances when an observation here returns true (or the user explicitly
// confirms a `.userConfirmation` step). Nothing is assumed.

@MainActor
enum SuccessObserver {

    /// Whether an OBSERVABLE check is currently satisfied. Returns nil for
    /// `.userConfirmation`, which is event-driven (handled by the engine), not
    /// pollable here.
    static func isSatisfied(_ check: SuccessCheck) -> Bool? {
        switch check {
        case .appFrontmost(let bundleId):
            return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId
        case .darkModeEnabled:
            return isDarkMode()
        case .userConfirmation:
            return nil
        }
    }

    /// Reads the system appearance directly — true when macOS is in Dark Mode.
    private static func isDarkMode() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }
}
