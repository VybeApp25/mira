import AppKit
import SwiftUI

// MARK: - Accessibility Service
//
// Single source of truth for system accessibility preferences.
// Views should prefer SwiftUI @Environment values for rendering;
// use this service for programmatic decisions and VoiceOver announcements.

@MainActor
final class AccessibilityService: ObservableObject {
    static let shared = AccessibilityService()

    @Published private(set) var reduceMotion:              Bool = false
    @Published private(set) var increaseContrast:          Bool = false
    @Published private(set) var differentiateWithoutColor: Bool = false
    @Published private(set) var isVoiceOverRunning:        Bool = false

    private init() {
        refresh()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared
        )
    }

    // MARK: - VoiceOver Announcement

    func announce(_ message: String) {
        guard let target = NSApp.keyWindow ?? NSApp.windows.first else { return }
        NSAccessibility.post(
            element: target,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message as NSString,
                .priority: 50 as NSNumber   // medium priority
            ]
        )
    }

    // MARK: - Refresh

    private func refresh() {
        let ws = NSWorkspace.shared
        reduceMotion              = ws.accessibilityDisplayShouldReduceMotion
        increaseContrast          = ws.accessibilityDisplayShouldIncreaseContrast
        differentiateWithoutColor = ws.accessibilityDisplayShouldDifferentiateWithoutColor
        isVoiceOverRunning        = (
            UserDefaults(suiteName: "com.apple.universalaccess")?.bool(forKey: "voiceOverOnOffKey") ?? false
        )
    }

    @objc private func displayOptionsChanged() {
        refresh()
    }
}

// MARK: - Animation helper

extension View {
    /// Replaces spring animations with a short ease when Reduce Motion is enabled.
    func animation<V: Equatable>(
        _ spring: Animation,
        reducedTo reduced: Animation = .easeInOut(duration: 0.10),
        reduceMotion: Bool,
        value: V
    ) -> some View {
        self.animation(reduceMotion ? reduced : spring, value: value)
    }
}
