// NotchModule.swift
// Phase 0 of the MacNotch parity work: the SHELL CONTRACT.
//
// The lesson from auditing MacNotch (docs/specs/macnotch-parity-audit.md) is that
// the shell is the product. ~22 panels obey ONE geometry with zero variance, and
// that consistency is what reads as expensive. Eight modules that each look
// slightly different would read as worse than three that are identical.
//
// So: every panel hosted in the notch conforms to `NotchModule`, and the shell —
// not the module — owns the header, the height, the collapse affordance, and the
// back chip. A module supplies content and declares intent; it never draws chrome.
//
// Height is deliberately an ENUM, not a CGFloat. MacNotch's own prefs store height
// as discrete levels plus a per-module "taller" boolean (`notesNotchHeightLevel…`,
// `translationNotchExpandedHeight = 0`, "Taller notch for the 7-day forecast"), not
// as measured point values. Mira already had the same idea in miniature —
// AnimationController.expandedH (252) vs .expandedTallH (420), picked per tab — so
// this generalizes existing behavior rather than replacing it.

import SwiftUI

// MARK: - Height levels

/// Discrete panel heights. Modules pick a level; the shell converts to points.
///
/// Keep this list SHORT. The whole point is that panels share a small set of
/// heights so switching modules doesn't produce arbitrary resizing. Adding a level
/// is a shell decision, not a module's.
enum NotchHeightLevel: String, Codable, CaseIterable, Equatable {
    /// Glanceable: a few rows, no scrolling. Weather current-conditions, Bluetooth.
    case compact
    /// The default working height — matches the long-standing expanded panel.
    case standard
    /// Content-dense: settings, agents, crons, a 7-day forecast with detail chips.
    case tall

    /// Point heights. These are the source of truth — deliberately literals rather
    /// than reads of `AnimationController.expandedH/.expandedTallH`, which are
    /// main-actor isolated and would make this nonisolated enum unusable off the
    /// main actor. `.standard` and `.tall` intentionally match those two constants.
    var points: CGFloat {
        switch self {
        case .compact:  return 190
        case .standard: return 252   // == AnimationController.expandedH
        case .tall:     return 420   // == AnimationController.expandedTallH
        }
    }

    /// The level a module steps up to when the user enables its "taller" toggle.
    /// Returns nil when there's nothing taller to step to.
    var taller: NotchHeightLevel? {
        switch self {
        case .compact:  return .standard
        case .standard: return .tall
        case .tall:     return nil
        }
    }
}

// MARK: - Header accessories

/// A circular icon-button in the module header's right cluster (refresh, info,
/// search, settings…). The shell lays these out so every module's controls land in
/// the same place — MacNotch's header cluster is in an identical spot on all ~22
/// panels, and that constancy is most of why it feels built rather than assembled.
struct NotchHeaderAccessory: Identifiable {
    let id: String
    let systemImage: String
    /// Tooltip / accessibility label. Required — an unlabeled icon button is a
    /// guessing game for anyone using VoiceOver.
    let label: String
    /// Rendered in the accent color and slightly emphasized. At most one per module.
    var isProminent: Bool = false
    let action: @MainActor () -> Void

    init(id: String,
         systemImage: String,
         label: String,
         isProminent: Bool = false,
         action: @escaping @MainActor () -> Void) {
        self.id = id
        self.systemImage = systemImage
        self.label = label
        self.isProminent = isProminent
        self.action = action
    }
}

/// Optional text shown next to the module title — MacNotch's `Calendar July 2026`
/// or `Notes 7`. Kept separate from the title so the shell can style it uniformly.
struct NotchHeaderSubtitle: Equatable {
    let text: String
    /// Draws as a rounded pill rather than plain secondary text (`[Today]`, `[Work >]`).
    var isPill: Bool = false
}

// MARK: - The module contract

/// A panel hosted in the expanded notch.
///
/// Conformers are reference types so the shell can hold them in a registry and so a
/// module can drive its own state (a fetch completing, a drill-in pushing) without
/// the shell re-creating it. `@MainActor` because everything here is UI.
@MainActor
protocol NotchModule: AnyObject, Identifiable {
    /// Stable across launches — used for ordering, pinning, and preferences keys.
    /// Never localize this.
    var id: String { get }

    /// Shown in the header and in the module browser. Localize freely.
    var title: String { get }

    /// SF Symbol for the dock, the carousel, and the module browser.
    var icon: String { get }

    /// Base height. May be stepped up by the user's "taller" preference when
    /// `allowsTallMode` is true — resolve with `resolvedHeightLevel`, never read
    /// this directly for layout.
    var heightLevel: NotchHeightLevel { get }

    /// Whether this module offers a "Taller notch" toggle in Settings. Only true
    /// for modules with genuinely more to show at height (a 7-day forecast row, an
    /// insights sidebar) — not as a way to dodge designing for the base height.
    var allowsTallMode: Bool { get }

    /// Right-aligned circular buttons in the header. Empty is fine.
    var headerAccessories: [NotchHeaderAccessory] { get }

    /// Optional text beside the title.
    var subtitle: NotchHeaderSubtitle? { get }

    /// The panel body. The shell draws the header, background, and collapse
    /// affordance around this — do not re-draw chrome here.
    func makeContent() -> AnyView

    /// Non-nil when the module has pushed a detail view. The shell renders a
    /// `‹ Back` chip with this title and calls `popDetail()` when tapped, so
    /// drill-in looks identical everywhere and never opens a window.
    var detailTitle: String? { get }
    func popDetail()

    /// Called when the module becomes / stops being the visible one. Use it to
    /// start and stop polling — a weather module refreshing every 10 minutes while
    /// invisible is wasted battery.
    func didAppear()
    func didDisappear()
}

// MARK: - Defaults

extension NotchModule {
    var allowsTallMode: Bool { false }
    var headerAccessories: [NotchHeaderAccessory] { [] }
    var subtitle: NotchHeaderSubtitle? { nil }
    var detailTitle: String? { nil }
    func popDetail() {}
    func didAppear() {}
    func didDisappear() {}

    /// UserDefaults key backing this module's "taller notch" preference.
    var tallModeKey: String { "mira_module_tall_\(id)" }

    /// The height the shell should actually use, after applying the user's
    /// per-module "taller" preference. Layout reads THIS, not `heightLevel`.
    var resolvedHeightLevel: NotchHeightLevel {
        guard allowsTallMode, UserDefaults.standard.bool(forKey: tallModeKey) else {
            return heightLevel
        }
        return heightLevel.taller ?? heightLevel
    }

    var resolvedHeight: CGFloat { resolvedHeightLevel.points }
}

// MARK: - Closure-backed module

/// A module whose content is supplied by a closure.
///
/// Exists so Mira's pre-existing panels (Home, Chat, Agents, Shelf, Settings…)
/// can join the carousel without being rewritten. Several of them need injected
/// dependencies — MiraState, the overlay controller, the capture service — that
/// are NOT singletons, so they can't be reached from a module constructed in
/// AppDelegate. Registering from inside the island view instead lets the closure
/// capture them from a scope where they exist.
///
/// New modules should conform to `NotchModule` directly. This is the migration
/// path for what already existed, not the pattern to copy.
@MainActor
final class ViewModule: NotchModule {

    let id: String
    let title: String
    let icon: String
    let heightLevel: NotchHeightLevel
    let allowsTallMode: Bool

    private let builder: () -> AnyView

    init(id: String,
         title: String,
         icon: String,
         heightLevel: NotchHeightLevel = .standard,
         allowsTallMode: Bool = false,
         @ViewBuilder content builder: @escaping () -> some View) {
        self.id = id
        self.title = title
        self.icon = icon
        self.heightLevel = heightLevel
        self.allowsTallMode = allowsTallMode
        let build = builder
        self.builder = { AnyView(build()) }
    }

    func makeContent() -> AnyView { builder() }
}

// MARK: - Type erasure

/// Erases `NotchModule` so the registry can hold a heterogeneous list.
/// (`Identifiable` gives the protocol an associated type via `ID`, so an existential
/// array of `any NotchModule` can't be used directly for ForEach ordering.)
@MainActor
final class AnyNotchModule: Identifiable {
    let base: any NotchModule

    /// Captured at init and stored `nonisolated` so `Identifiable` conformance
    /// doesn't cross into main-actor code (which SwiftUI would flag as a data race
    /// under Swift 6). Module ids are stable for the life of the module anyway.
    nonisolated let id: String

    init(_ base: any NotchModule) {
        self.base = base
        self.id = base.id
    }

    var title: String { base.title }
    var icon: String { base.icon }
    var allowsTallMode: Bool { base.allowsTallMode }
    var headerAccessories: [NotchHeaderAccessory] { base.headerAccessories }
    var subtitle: NotchHeaderSubtitle? { base.subtitle }
    var detailTitle: String? { base.detailTitle }
    var resolvedHeightLevel: NotchHeightLevel { base.resolvedHeightLevel }
    var resolvedHeight: CGFloat { base.resolvedHeight }

    func makeContent() -> AnyView { base.makeContent() }
    func popDetail() { base.popDetail() }
    func didAppear() { base.didAppear() }
    func didDisappear() { base.didDisappear() }
}
