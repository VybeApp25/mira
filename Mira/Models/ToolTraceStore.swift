import Foundation

// MARK: - Trace entry

struct ToolTrace: Identifiable {
    let id          = UUID()
    let timestamp:  Date
    let toolName:   String
    let argsJSON:   String
    let result:     String
    let durationMs: Int

    // MARK: - Parsed args

    var args: [String: Any] {
        guard let data = argsJSON.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    // MARK: - One-line summary shown in collapsed row

    var summary: String {
        switch toolName {
        case "remember":
            let k = args["key"]   as? String ?? "?"
            let v = args["value"] as? String ?? "?"
            return "\(k) = \(v)"
        case "save_content":
            let dest  = args["destination"] as? String ?? "?"
            let title = args["title"] as? String ?? String((args["content"] as? String ?? "").prefix(30))
            return "\(dest) · \(title)"
        case "recall_memories":
            return "query: \(args["query"] as? String ?? "?")"
        case "forget":
            return "key: \(args["key"] as? String ?? "?")"
        case "get_current_context":
            return "screen snapshot"
        case "open_application":
            return args["app_name"] as? String ?? "?"
        case "search_web":
            return args["query"] as? String ?? "?"
        case "control_music":
            return args["action"] as? String ?? "?"
        case "run_shortcut":
            return args["shortcut_name"] as? String ?? "?"
        case "get_calendar_events":
            return "next \(args["days_ahead"] as? Int ?? 1) day(s)"
        default:
            return args.values.compactMap { $0 as? String }.first ?? ""
        }
    }

    // MARK: - Routing signal (catches content-in-memory drift)

    enum Signal { case correct, ambiguous, suspicious }

    var signal: Signal {
        guard toolName == "remember" else { return .correct }
        let value = args["value"] as? String ?? ""
        let words = value.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
        if words > 10 { return .suspicious }   // long sentence → content leaking into memory
        if words > 5  { return .ambiguous }    // borderline
        return .correct
    }

    var signalColor: String {
        switch signal {
        case .correct:    return "green"
        case .ambiguous:  return "yellow"
        case .suspicious: return "red"
        }
    }
}

// MARK: - Store

/// Session-scoped ring buffer of the last 50 tool executions.
/// Written by RealtimeVoiceService.runTool; read by ToolTraceView.
final class ToolTraceStore: ObservableObject {
    static let shared = ToolTraceStore()

    @Published private(set) var traces: [ToolTrace] = []   // newest first
    private let cap = 50

    private init() {}

    func record(toolName: String, argsJSON: String, result: String, durationMs: Int) {
        let entry = ToolTrace(timestamp: Date(), toolName: toolName,
                              argsJSON: argsJSON, result: result, durationMs: durationMs)
        traces.insert(entry, at: 0)
        if traces.count > cap { traces = Array(traces.prefix(cap)) }
    }

    func clear() { traces = [] }
}
