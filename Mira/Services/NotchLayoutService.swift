// NotchLayoutService.swift
// How wide the expanded panel is.
//
// MacNotch has a corner control that widens the notch for modules — its own copy
// describes expanding to "three devices per row in a scrollable grid" and a
// dashboard second row "with the notch widening to match". Mira's expanded panel
// was a single fixed 724pt, so content-dense modules (agents, settings, a device
// grid) had one width to live in whether they needed it or not.
//
// This is width only. Height is already the module's own decision through
// NotchHeightLevel, and the two are genuinely different: height is a property of
// the content, width is a preference about how much of the screen you want the
// notch to take. So this is a user toggle that persists, not a per-module
// declaration.

import SwiftUI

@MainActor
final class NotchLayoutService: ObservableObject {

    static let shared = NotchLayoutService()

    private static let key = "mira_notch_maximized_v1"

    @Published var isMaximized: Bool = UserDefaults.standard.bool(forKey: key) {
        didSet {
            guard oldValue != isMaximized else { return }
            UserDefaults.standard.set(isMaximized, forKey: Self.key)
        }
    }

    private init() {}

    /// The panel's width right now.
    ///
    /// Both values must stay inside MiraIslandWindowManager.windowW — the panel
    /// is drawn INSIDE a fixed-size transparent window, so a panel wider than
    /// its container is silently clipped rather than failing loudly.
    var expandedWidth: CGFloat {
        isMaximized ? AnimationController.expandedWideW : AnimationController.expandedW
    }

    func toggle() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            isMaximized.toggle()
        }
    }
}
