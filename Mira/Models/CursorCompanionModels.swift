import Foundation
import SwiftUI

// MARK: - Action spec

enum CompanionActionStyle: Equatable {
    case primary, secondary, destructive
}

struct CompanionActionSpec: Identifiable, Equatable {
    let id:    UUID
    let label: String
    let style: CompanionActionStyle
    let tag:   String

    init(_ label: String, style: CompanionActionStyle = .primary, tag: String) {
        id = UUID()
        self.label = label
        self.style = style
        self.tag   = tag
    }

    // Convenience factories
    static func openIsland()  -> CompanionActionSpec { .init("Open Mira",        style: .secondary,  tag: "open_island") }
    static func viewLibrary() -> CompanionActionSpec { .init("View in Library",  style: .secondary,  tag: "view_library") }
    static func openSite()    -> CompanionActionSpec { .init("Open Site",        style: .primary,    tag: "open_site") }
    static func reconnect()   -> CompanionActionSpec { .init("Reconnect",        style: .primary,    tag: "reconnect") }
    static func confirm()     -> CompanionActionSpec { .init("Confirm",          style: .primary,    tag: "confirm") }
    static func cancel()      -> CompanionActionSpec { .init("Cancel",           style: .secondary,  tag: "cancel") }
    static func improve()     -> CompanionActionSpec { .init("Improve",          style: .secondary,  tag: "improve") }
    static func retry()       -> CompanionActionSpec { .init("Retry",            style: .primary,    tag: "retry") }
}

// MARK: - Companion state

enum CursorCompanionState: Equatable {
    case idle
    case reply(text: String)
    case agentRunning(title: String, step: String, current: Int, total: Int, progress: Double)
    case question(text: String, options: [String], jobId: UUID?)
    case confirmation(summary: String, actions: [CompanionActionSpec])
    case success(title: String, actions: [CompanionActionSpec])
    case error(message: String, recoverable: Bool, actions: [CompanionActionSpec])

    var isInteractive: Bool {
        switch self {
        case .question, .confirmation:  return true
        case .error(_, true, _):        return true
        default:                         return false
        }
    }

    var autoDismissDelay: TimeInterval? {
        switch self {
        case .reply:              return 4
        case .success:            return 6
        case .error(_, false, _): return 8
        default:                  return nil
        }
    }

    var stateLabel: String {
        switch self {
        case .idle:         return "idle"
        case .reply:        return "reply"
        case .agentRunning: return "agent_running"
        case .question:     return "question"
        case .confirmation: return "confirmation"
        case .success:      return "success"
        case .error:        return "error"
        }
    }

    static func == (lhs: CursorCompanionState, rhs: CursorCompanionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.reply(let a), .reply(let b)): return a == b
        case (.agentRunning(let a, let b, let c, let d, _),
              .agentRunning(let e, let f, let g, let h, _)):
            return a == e && b == f && c == g && d == h
        case (.question(let a, let b, _), .question(let c, let d, _)):
            return a == c && b == d
        case (.confirmation(let a, _), .confirmation(let b, _)): return a == b
        case (.success(let a, _),      .success(let b, _)):      return a == b
        case (.error(let a, let b, _), .error(let c, let d, _)): return a == c && b == d
        default: return false
        }
    }
}

// MARK: - Event

enum CursorCompanionEvent {
    case chatReply(String)
    case agentStarted(title: String, totalSteps: Int)
    case agentProgress(step: String, current: Int, total: Int, progress: Double)
    case agentCompleted(title: String, actions: [CompanionActionSpec])
    case agentFailed(message: String, actions: [CompanionActionSpec])
    case question(text: String, options: [String], jobId: UUID?)
    case confirmation(summary: String, actions: [CompanionActionSpec])
    case success(title: String, actions: [CompanionActionSpec])
    case error(message: String, recoverable: Bool, actions: [CompanionActionSpec])
    case dismiss
}

// MARK: - View model (owned by manager, observed by SwiftUI — no retain cycle)

@MainActor
final class CursorCompanionViewModel: ObservableObject {
    @Published var state:    CursorCompanionState = .idle
    @Published var isPinned: Bool                 = false
}

// MARK: - Notification names

extension Notification.Name {
    static let companionDidConfirm   = Notification.Name("mira.companion.didConfirm")
    static let companionDidCancel    = Notification.Name("mira.companion.didCancel")
    static let companionActionTapped = Notification.Name("mira.companion.actionTapped")
}

// MARK: - Telemetry

struct CCTelemetryRecord {
    let timestamp: Date
    let eventName: String
    let detail:    String?
}

@MainActor
final class CursorCompanionTelemetry {
    static let shared = CursorCompanionTelemetry()

    private(set) var records: [CCTelemetryRecord] = []
    private let cap = 1000
    private init() {}

    func log(_ name: String, detail: String? = nil) {
        records.append(.init(timestamp: .now, eventName: name, detail: detail))
        if records.count > cap { records.removeFirst(records.count - cap) }
    }

    func appeared(state: String)                          { log("appeared",      detail: state) }
    func dismissed(state: String, after seconds: Double)  { log("dismissed",     detail: "\(state)/\(Int(seconds))s") }
    func actionTapped(_ label: String)                    { log("action_tapped", detail: label) }
    func pinToggled(pinned: Bool)                         { log(pinned ? "pinned" : "unpinned") }

    var totalAppearances: Int    { records.filter { $0.eventName == "appeared"      }.count }
    var totalActionTaps:  Int    { records.filter { $0.eventName == "action_tapped" }.count }
    var actionTapRate:    Double {
        let a = Double(totalAppearances), t = Double(totalActionTaps)
        return a > 0 ? t / a : 0
    }
}
