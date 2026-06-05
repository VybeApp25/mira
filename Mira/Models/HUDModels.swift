// HUDModels.swift
// Phase 2 — HUD data types.
//
// Kept simple and Equatable so AnimationController can use
// HUDMode as a @Published animation value without associated values.

import Foundation

// MARK: - HUDMode (drives AnimationController overlay selection)

/// Three-state enum that drives which overlay the island shows.
/// Lives separately from IslandState to avoid touching the existing
/// .collapsed / .expanded animation pair.
enum HUDMode: Equatable {
    case idle       // No overlay — island shows normal tab content
    case running    // HUD stream visible (agent is working)
    case done       // Result + action chips visible (agent finished)
    case blocked    // Agent stopped, needs user input; does not auto-clear
}

// MARK: - HUDCategory (styling / icon hint for each update)

enum HUDCategory {
    case starting       // Launched agent
    case analyzing      // Reading files, understanding context
    case working        // Writing, editing, creating
    case browsing       // Web search or computer use
    case integrating    // Using Composio / external app
    case checkpointing  // Saving a checkpoint
    case completing     // Wrapping up
    case blocked        // Needs user input

    var icon: String {
        switch self {
        case .starting:      return "bolt.fill"
        case .analyzing:     return "magnifyingglass"
        case .working:       return "pencil"
        case .browsing:      return "globe"
        case .integrating:   return "link"
        case .checkpointing: return "pin.fill"
        case .completing:    return "checkmark.circle"
        case .blocked:       return "exclamationmark.triangle"
        }
    }
}

// MARK: - HUDUpdate (single radio-dispatch message)

struct HUDUpdate: Identifiable {
    let id       = UUID()
    let message:  String
    let category: HUDCategory
    let timestamp = Date()
}
