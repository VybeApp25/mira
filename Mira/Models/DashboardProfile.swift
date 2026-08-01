// DashboardProfile.swift
// The Dashboard's data model: named profiles, each a full slot layout.
//
// Schema taken from MacNotch's own preferences, measured in the parity audit
// (docs/specs/macnotch-parity-audit.md §6.2) rather than from their marketing:
//
//   • The "four widget slots" the site advertises are really EIGHT —
//     dashboardLeftWidget / CenterWidget / RightWidget / FourthWidget through
//     EighthWidget, with dashboardTwoRowsEnabled turning on the second row and
//     dashboardTwoRowsNotchExpandedHeight growing the panel to fit.
//   • Six factory profiles ship, each carrying icon, colorHex, its slots, and
//     a headerDisplay of either the word "Dashboard" or the date.
//
// The profiles below keep MacNotch's names, icons and colours, and their intent
// slot for slot. Where they reference a widget Mira doesn't have, the nearest
// Mira widget takes the place rather than the slot sitting empty — noted per
// profile. Copying a layout that references widgets that don't exist would
// produce six identical grids of blanks.

import SwiftUI

// MARK: - Widgets

/// What can occupy a Dashboard slot.
///
/// Deliberately its own type rather than a reuse of `DockWidgetType`. Most cases
/// map straight onto a dock widget and say so, but the Dashboard also surfaces
/// things that were never dock widgets — Screen Time, Day Progress, Events —
/// and those only became possible because this branch built the services behind
/// them. Tying the two enums together would have capped the Dashboard at
/// whatever the dock happened to support.
enum DashboardWidget: String, Codable, CaseIterable, Identifiable {
    case weather, media, pomodoro, apps, toggles, battery, systemStats, clock
    case events, dayProgress, screenTime, notes, bluetooth, quotes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .weather:     return "Weather"
        case .media:       return "Media"
        case .pomodoro:    return "Pomodoro"
        case .apps:        return "Apps"
        case .toggles:     return "Quick toggles"
        case .battery:     return "Battery"
        case .systemStats: return "System"
        case .clock:       return "Clock"
        case .events:      return "Events"
        case .dayProgress: return "Day progress"
        case .screenTime:  return "Screen Time"
        case .notes:       return "Notes"
        case .bluetooth:   return "Bluetooth"
        case .quotes:      return "Quotes"
        }
    }

    var icon: String {
        switch self {
        case .weather:     return "cloud.sun"
        case .media:       return "music.note"
        case .pomodoro:    return "timer"
        case .apps:        return "square.grid.2x2"
        case .toggles:     return "switch.2"
        case .battery:     return "battery.75"
        case .systemStats: return "cpu"
        case .clock:       return "clock"
        case .events:      return "calendar"
        case .dayProgress: return "chart.bar.xaxis"
        case .screenTime:  return "hourglass"
        case .notes:       return "note.text"
        case .bluetooth:   return "wave.3.right"
        case .quotes:      return "quote.opening"
        }
    }

    /// The dock widget that already draws this, when one does. Nil means the
    /// Dashboard draws its own card.
    var dockEquivalent: DockWidgetType? {
        switch self {
        case .weather:     return .weather
        case .media:       return .nowPlaying
        case .pomodoro:    return .pomodoro
        case .apps:        return .appLauncher
        case .toggles:     return .toggles
        case .battery:     return .battery
        case .systemStats: return .systemStats
        case .clock:       return .clock
        default:           return nil
        }
    }
}

// MARK: - Profile

struct DashboardProfile: Codable, Identifiable, Equatable {

    /// What the header shows beside the profile pill.
    enum HeaderDisplay: String, Codable { case dashboard, date }

    let id: String
    var name: String
    var icon: String
    /// Stored as hex so a profile round-trips through JSON without a Color
    /// coding shim.
    var colorHex: String
    /// Eight slots. The first four are row one; the rest appear only when
    /// `twoRows` is on. Optional because a slot can be deliberately empty.
    var slots: [DashboardWidget?]
    var twoRows: Bool
    var headerDisplay: HeaderDisplay

    var color: Color { Color(hex: colorHex) }

    /// Slots actually on screen for this profile.
    var visibleSlots: [DashboardWidget?] {
        Array(slots.prefix(twoRows ? 8 : 4))
    }

    init(id: String,
         name: String,
         icon: String,
         colorHex: String,
         slots: [DashboardWidget?],
         twoRows: Bool = false,
         headerDisplay: HeaderDisplay = .dashboard) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        // Always carry eight so turning two rows on never has to invent slots.
        var padded = slots
        while padded.count < 8 { padded.append(nil) }
        self.slots = Array(padded.prefix(8))
        self.twoRows = twoRows
        self.headerDisplay = headerDisplay
    }
}

// MARK: - Factory profiles

extension DashboardProfile {

    /// MacNotch's six, with their names, SF Symbols and colours (audit §6.2).
    /// Substitutions, all because Mira has no equivalent widget:
    ///   Actions → Apps · Summary → Day progress · Reminders/Tasks → Events
    ///   Calculator → System · Notifications → Screen Time
    static let factory: [DashboardProfile] = [
        DashboardProfile(
            id: "quick", name: "Quick", icon: "rectangle.split.3x1", colorHex: "5EEAD4",
            slots: [.toggles, .screenTime, .apps, .clock]),

        DashboardProfile(
            id: "work", name: "Work", icon: "briefcase.fill", colorHex: "B78A65",
            slots: [.events, .apps, .pomodoro, .dayProgress]),

        DashboardProfile(
            id: "personal", name: "Personal", icon: "person.fill", colorHex: "A78BFA",
            slots: [.dayProgress, .apps, .bluetooth, .media]),

        DashboardProfile(
            id: "focus", name: "Focus", icon: "leaf.fill", colorHex: "047857",
            slots: [.notes, .pomodoro, .media, .screenTime]),

        DashboardProfile(
            id: "productivity", name: "Productivity", icon: "checklist", colorHex: "FF9230",
            slots: [.notes, .events, .dayProgress, .quotes]),

        DashboardProfile(
            id: "simple", name: "Simple", icon: "sparkles", colorHex: "0EA5E9",
            slots: [.media, .dayProgress, .quotes, .weather],
            headerDisplay: .date)
    ]
}

// MARK: - Store

@MainActor
final class DashboardProfileStore: ObservableObject {

    static let shared = DashboardProfileStore()

    @Published private(set) var profiles: [DashboardProfile] = []
    @Published private(set) var selectedID: String = "work"

    private let profilesKey = "mira_dashboard_profiles_v1"
    private let selectedKey = "mira_dashboard_selected_profile_v1"

    private init() {
        profiles = Self.load() ?? DashboardProfile.factory
        selectedID = UserDefaults.standard.string(forKey: selectedKey) ?? "work"
        if !profiles.contains(where: { $0.id == selectedID }) {
            selectedID = profiles.first?.id ?? "work"
        }
    }

    var selected: DashboardProfile {
        profiles.first { $0.id == selectedID } ?? profiles.first ?? DashboardProfile.factory[1]
    }

    func select(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedID = id
        UserDefaults.standard.set(id, forKey: selectedKey)
    }

    func setSlot(_ widget: DashboardWidget?, at index: Int) {
        guard let profileIndex = profiles.firstIndex(where: { $0.id == selectedID }),
              profiles[profileIndex].slots.indices.contains(index) else { return }
        profiles[profileIndex].slots[index] = widget
        persist()
    }

    func setTwoRows(_ on: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedID }) else { return }
        profiles[index].twoRows = on
        persist()
    }

    /// Restore the shipped layout for the current profile. Editing eight slots
    /// by hand is easy to get into a mess and hard to get out of.
    func resetSelectedToFactory() {
        guard let index = profiles.firstIndex(where: { $0.id == selectedID }),
              let original = DashboardProfile.factory.first(where: { $0.id == selectedID })
        else { return }
        profiles[index] = original
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: profilesKey)
    }

    private static func load() -> [DashboardProfile]? {
        guard let data = UserDefaults.standard.data(forKey: "mira_dashboard_profiles_v1"),
              let saved = try? JSONDecoder().decode([DashboardProfile].self, from: data),
              !saved.isEmpty
        else { return nil }

        // A profile added by a later build should appear rather than staying
        // invisible until the user resets. Same reasoning as the module
        // registry's seen-ids pinning and the Pomodoro preset list.
        let known = Set(saved.map(\.id))
        return saved + DashboardProfile.factory.filter { !known.contains($0.id) }
    }
}

// `Color(hex:)` lives in DesignSystem.swift — profiles store colours as hex so
// they round-trip through JSON without a Color coding shim.
