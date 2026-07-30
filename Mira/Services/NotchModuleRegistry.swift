// NotchModuleRegistry.swift
// Owns which modules exist, what order they're in, which are pinned, and which one
// is currently showing. Phase 0 of the MacNotch parity work.
//
// Two distinct orderings, which the parity audit originally conflated:
//
//   • CAROUSEL ORDER — every enabled module, in user-chosen order. This is the
//     primary navigation: you swipe horizontally between modules. MacNotch's
//     Settings says so outright: "Drag modules to reorder them in the horizontal
//     swipe carousel."
//   • PINNED — a SUBSET the user chooses, drawn as circular buttons below the slab
//     for one-tap access ("Select which modules appear pinned at the bottom of the
//     notch for quick access", plus a `Dock Favorites` pane).
//
// The audit's first pass called the dock "the module switcher" and couldn't explain
// why the button count varied between 5 and 16 across screenshots. It varies because
// it's user-pinned. Getting this wrong would have produced a dock that grows
// unusably wide once a dozen modules exist.

import SwiftUI
import Combine

@MainActor
final class NotchModuleRegistry: ObservableObject {

    static let shared = NotchModuleRegistry()

    // MARK: - Published state

    /// Every registered module, in carousel order.
    @Published private(set) var modules: [AnyNotchModule] = []

    /// id of the module currently on screen.
    @Published private(set) var selectedID: String?

    /// ids pinned to the dock strip, in dock order.
    @Published private(set) var pinnedIDs: [String] = []

    // MARK: - Preference keys

    private let orderKey  = "mira_notch_module_order_v1"
    private let pinnedKey = "mira_notch_module_pinned_v1"
    private let hiddenKey = "mira_notch_module_hidden_v1"

    /// Modules the user has switched off entirely. They keep their carousel
    /// position so re-enabling doesn't shuffle everything.
    @Published private(set) var hiddenIDs: Set<String> = []

    private init() {
        pinnedIDs = UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []
        hiddenIDs = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
    }

    // MARK: - Registration

    /// Registers a module. Idempotent by id so a double-register during startup
    /// can't produce two copies in the carousel.
    func register(_ module: any NotchModule) {
        guard !modules.contains(where: { $0.id == module.id }) else { return }
        modules.append(AnyNotchModule(module))
        applySavedOrder()
        applyDefaultPinsIfNeeded()
        if selectedID == nil { selectedID = visibleModules.first?.id }
    }

    /// On first run the dock would otherwise be empty, which reads as broken
    /// rather than as "nothing pinned yet". Pin whatever is registered, up to the
    /// cap. Runs once — the flag means a user who deliberately unpins everything
    /// doesn't get their choices re-added on the next launch.
    private let defaultPinsKey = "mira_notch_module_default_pins_v1"

    private func applyDefaultPinsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: defaultPinsKey) else { return }
        guard !modules.isEmpty else { return }
        pinnedIDs = Array(visibleModules.prefix(Self.maxPinned).map(\.id))
        UserDefaults.standard.set(pinnedIDs, forKey: pinnedKey)
        UserDefaults.standard.set(true, forKey: defaultPinsKey)
    }

    func register(_ newModules: [any NotchModule]) {
        newModules.forEach(register)
    }

    // MARK: - Queries

    /// Carousel contents: registered, not hidden.
    var visibleModules: [AnyNotchModule] {
        modules.filter { !hiddenIDs.contains($0.id) }
    }

    /// The circular strip below the slab. Pinned ids that still resolve and aren't
    /// hidden, in pin order.
    var pinnedModules: [AnyNotchModule] {
        pinnedIDs.compactMap { id in
            visibleModules.first { $0.id == id }
        }
    }

    var selected: AnyNotchModule? {
        guard let selectedID else { return visibleModules.first }
        return visibleModules.first { $0.id == selectedID } ?? visibleModules.first
    }

    /// Height the shell should animate to for the current module. Falls back to
    /// `.standard` when nothing is registered yet so the panel never collapses to
    /// zero during startup.
    var currentHeight: CGFloat {
        selected?.resolvedHeight ?? NotchHeightLevel.standard.points
    }

    /// Case- and diacritic-insensitive title match, for the module browser's
    /// "Search modules..." field.
    func search(_ query: String) -> [AnyNotchModule] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return visibleModules }
        return visibleModules.filter {
            $0.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // MARK: - Selection

    func select(_ id: String) {
        guard id != selectedID else { return }
        guard visibleModules.contains(where: { $0.id == id }) else { return }
        selected?.didDisappear()
        selectedID = id
        selected?.didAppear()
        notifyHeightChanged()
    }

    /// Carousel navigation. Wraps, so swiping past the end returns to the start —
    /// with a small module count, a dead end at each edge feels broken.
    func advance(by offset: Int) {
        let list = visibleModules
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedID } ?? 0
        let next = ((current + offset) % list.count + list.count) % list.count
        select(list[next].id)
    }

    // MARK: - Ordering

    func move(id: String, to index: Int) {
        guard let from = modules.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(index, modules.count - 1))
        let module = modules.remove(at: from)
        modules.insert(module, at: clamped)
        persistOrder()
    }

    private func applySavedOrder() {
        guard let saved = UserDefaults.standard.stringArray(forKey: orderKey), !saved.isEmpty else { return }
        // Saved ids first in their stored order; anything new (added by an app
        // update) keeps its registration order and lands at the end.
        let rank = Dictionary(uniqueKeysWithValues: saved.enumerated().map { ($0.element, $0.offset) })
        modules.sort { a, b in
            switch (rank[a.id], rank[b.id]) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return false   // stable: preserve registration order
            }
        }
    }

    private func persistOrder() {
        UserDefaults.standard.set(modules.map(\.id), forKey: orderKey)
    }

    // MARK: - Pinning

    func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    /// Cap the dock so it can't outgrow the slab. MacNotch tops out around 16;
    /// past that the circles shrink below a comfortable hit target.
    static let maxPinned = 12

    @discardableResult
    func togglePin(_ id: String) -> Bool {
        if let idx = pinnedIDs.firstIndex(of: id) {
            pinnedIDs.remove(at: idx)
        } else {
            guard pinnedIDs.count < Self.maxPinned else { return false }
            pinnedIDs.append(id)
        }
        UserDefaults.standard.set(pinnedIDs, forKey: pinnedKey)
        return true
    }

    // MARK: - Hiding

    func isHidden(_ id: String) -> Bool { hiddenIDs.contains(id) }

    func setHidden(_ hidden: Bool, for id: String) {
        if hidden { hiddenIDs.insert(id) } else { hiddenIDs.remove(id) }
        UserDefaults.standard.set(Array(hiddenIDs), forKey: hiddenKey)
        // Don't strand the selection on a module the user just hid.
        if hidden, selectedID == id {
            selectedID = visibleModules.first?.id
            notifyHeightChanged()
        }
    }

    // MARK: - Tall mode

    func allowsTallMode(_ id: String) -> Bool {
        modules.first { $0.id == id }?.allowsTallMode ?? false
    }

    func isTallModeOn(_ id: String) -> Bool {
        UserDefaults.standard.bool(forKey: "mira_module_tall_\(id)")
    }

    func setTallMode(_ on: Bool, for id: String) {
        UserDefaults.standard.set(on, forKey: "mira_module_tall_\(id)")
        objectWillChange.send()
        if id == selectedID { notifyHeightChanged() }
    }

    // MARK: - Private

    /// The island's hover zone is sized from the panel height; without this a
    /// taller panel collapses as soon as the cursor moves into its lower half.
    private func notifyHeightChanged() {
        NotificationCenter.default.post(name: .miraIslandHeightChanged, object: nil)
    }
}
