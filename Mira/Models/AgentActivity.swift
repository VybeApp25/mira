import SwiftUI

// MARK: - AgentActivityStatus
//
// Lightweight live-state enum for an *ephemeral* agent activity — the kind that
// tracks a single computer-use / autonomy run while it happens, then disappears.
// This is deliberately separate from AgentJobStatus (heavy, persisted website /
// research jobs) and from AgentTask (the persisted history record in
// AgentTaskStore). Nothing here is written to disk.

enum AgentActivityStatus: String, Equatable {
    case queued
    case running
    case thinking
    case processing
    case callingTools
    case responding
    case completed
    case failed

    var isActive: Bool {
        switch self {
        case .completed, .failed: return false
        default:                  return true
        }
    }

    var isTerminal: Bool { !isActive }

    var label: String {
        switch self {
        case .queued:       return "Queued"
        case .running:      return "Working"
        case .thinking:     return "Thinking"
        case .processing:   return "Processing"
        case .callingTools: return "Acting"
        case .responding:   return "Responding"
        case .completed:    return "Done"
        case .failed:       return "Failed"
        }
    }

    // Reuses the same palette as the persisted job chips so the two chip
    // families read as one system in the bottom-right stack.
    var color: Color {
        switch self {
        case .queued, .running, .processing, .callingTools:
            return Color(red: 0.18, green: 0.56, blue: 1.00)   // blue
        case .thinking, .responding:
            return Color(red: 0.55, green: 0.45, blue: 1.00)   // violet
        case .completed:
            return Color(red: 0.20, green: 0.84, blue: 0.29)   // green
        case .failed:
            return Color(red: 1.00, green: 0.35, blue: 0.35)   // red
        }
    }

    var icon: String {
        switch self {
        case .queued:       return "clock"
        case .running:      return "cpu"
        case .thinking:     return "brain"
        case .processing:   return "gearshape"
        case .callingTools: return "cursorarrow.rays"
        case .responding:   return "text.bubble"
        case .completed:    return "checkmark"
        case .failed:       return "exclamationmark.triangle"
        }
    }
}

// MARK: - AgentActivity
//
// One live agent activity rendered as a floating chip. Value type, in-memory
// only. `title` is the task ("Open Calendar and add lunch"), `subtitle` is the
// live status detail ("Clicking…", "Reading screen…").

struct AgentActivity: Identifiable, Equatable {
    let id: UUID
    var title: String
    var subtitle: String
    var status: AgentActivityStatus
    var progress: Double          // 0.0 → 1.0, soft/creeping for indeterminate work
    let createdAt: Date

    init(title: String, subtitle: String = "", status: AgentActivityStatus = .queued) {
        self.id        = UUID()
        self.title     = title
        self.subtitle  = subtitle
        self.status    = status
        self.progress  = 0
        self.createdAt = Date()
    }
}
