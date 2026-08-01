// PreviewModeService.swift
// The amber "you are editing this in Settings, so it is not live right now"
// state in the notch header.
//
// From the parity audit: MacNotch shows a live static preview of the overlay
// being configured, with a warning in the header — its own wording is "Editing
// Snap Zones in Settings. Snap inactive." — plus an eye icon and a "Preview
// mode" label.
//
// WHY THIS IS WORTH A SERVICE RATHER THAN A BOOLEAN IN ONE VIEW. The problem it
// solves is a specific, silent one: while you are editing Snap Zones, dragging a
// window to the top of the screen does NOT snap. That is correct — the feature
// is suspended so your drag does not fight the editor — but nothing said so, so
// the honest reading from the user's side is "Snap Zones is broken". A feature
// that is deliberately inert has to say it is deliberately inert, and any
// feature that gets a settings editor will have the same problem.
//
// Deliberately not a preview RENDERER. MacNotch draws a static copy of the
// overlay in the notch; this is the warning half, which is the part that
// prevents the misreading. Drawing a second copy of every editable overlay is
// considerably more surface for considerably less benefit, and would have to be
// re-done per overlay anyway.

import SwiftUI

@MainActor
final class PreviewModeService: ObservableObject {

    static let shared = PreviewModeService()

    struct State: Equatable {
        /// What is being edited, e.g. "Snap Zones".
        let feature: String
        /// What is consequently not happening, e.g. "Snap inactive".
        let suspended: String
    }

    @Published private(set) var active: State?

    private init() {}

    /// Called by a settings pane when it opens. Naming both the feature and what
    /// is suspended is the whole contract — "Preview mode" alone tells the user
    /// nothing about why their drag did nothing.
    func begin(feature: String, suspended: String) {
        let next = State(feature: feature, suspended: suspended)
        if active != next { active = next }
    }

    func end(feature: String) {
        // Only clear if this is the pane that set it. Two panes closing out of
        // order would otherwise leave the banner up after the second closes, or
        // clear it while the first is still editing.
        if active?.feature == feature { active = nil }
    }

    func endAll() { active = nil }
}

// MARK: - Banner

/// Amber rather than red: this is not an error, it is a state the user chose by
/// opening the editor, and colouring it as a failure would be its own kind of
/// lying.
struct PreviewModeBanner: View {

    @ObservedObject private var service = PreviewModeService.shared

    private let amber = Color(red: 0.98, green: 0.74, blue: 0.35)

    var body: some View {
        if let active = service.active {
            HStack(spacing: 6) {
                Image(systemName: "eye")
                    .font(.system(size: 9, weight: .semibold))
                Text("Preview mode")
                    .font(.system(size: 9, weight: .bold))
                Text("Editing \(active.feature) in Settings. \(active.suspended).")
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundColor(amber)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(amber.opacity(0.14)))
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Preview mode. Editing \(active.feature) in Settings. \(active.suspended).")
        }
    }
}
