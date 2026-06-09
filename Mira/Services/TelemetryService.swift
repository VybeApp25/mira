import Foundation

// MARK: - Record (on-disk format)

struct TelemetryRecord: Codable {
    let id:         UUID
    let timestamp:  Date
    let event:      String
    var properties: [String: String]
}

// MARK: - Event (typed call-site API)

enum TelemetryEvent {
    // Agent lifecycle
    case agentStarted(jobId: UUID, jobType: String)
    case agentCompleted(jobId: UUID, jobType: String, durationSeconds: Double)
    case agentFailed(jobId: UUID, jobType: String, reason: String)

    // Cursor Companion
    case companionShown(state: String)
    case companionDismissed(state: String, afterSeconds: Double)
    case companionActionTapped(action: String)

    // Publishing
    case publishStarted(jobId: UUID, provider: String)
    case publishSucceeded(jobId: UUID, provider: String)
    case publishFailed(jobId: UUID, provider: String, reason: String)

    // Improvements
    case improvementRequested(jobId: UUID, sourceEntryId: UUID)
    case improvementApproved(jobId: UUID, scoreDelta: Double?)
    case improvementRejected(jobId: UUID)

    // Versions
    case versionRestored(entryId: UUID)

    // Intelligence architecture
    case policyApplied(jobId: UUID, categories: String)
    case causalInsightComputed(category: String, causalEffect: Double, nTreated: Int, nControl: Int)
    case outcomeEvaluated(jobId: UUID, predictedImpact: Double, actualImpact: Double, errorDelta: Double)
    case attentionDirectiveIssued(section: String, urgency: Double)

    // MARK: Serialisation helpers

    var name: String {
        switch self {
        case .agentStarted:           return "agent_started"
        case .agentCompleted:         return "agent_completed"
        case .agentFailed:            return "agent_failed"
        case .companionShown:         return "companion_shown"
        case .companionDismissed:     return "companion_dismissed"
        case .companionActionTapped:  return "companion_action_tapped"
        case .publishStarted:         return "publish_started"
        case .publishSucceeded:       return "publish_succeeded"
        case .publishFailed:          return "publish_failed"
        case .improvementRequested:   return "improvement_requested"
        case .improvementApproved:    return "improvement_approved"
        case .improvementRejected:    return "improvement_rejected"
        case .versionRestored:            return "version_restored"
        case .policyApplied:              return "policy_applied"
        case .causalInsightComputed:      return "causal_insight_computed"
        case .outcomeEvaluated:           return "outcome_evaluated"
        case .attentionDirectiveIssued:   return "attention_directive_issued"
        }
    }

    var properties: [String: String] {
        switch self {
        case .agentStarted(let jobId, let jobType):
            return ["jobId": jobId.uuidString, "jobType": jobType]

        case .agentCompleted(let jobId, let jobType, let dur):
            return ["jobId": jobId.uuidString, "jobType": jobType,
                    "durationSeconds": String(format: "%.1f", dur)]

        case .agentFailed(let jobId, let jobType, let reason):
            return ["jobId": jobId.uuidString, "jobType": jobType, "reason": reason]

        case .companionShown(let state):
            return ["state": state]

        case .companionDismissed(let state, let secs):
            return ["state": state, "afterSeconds": String(format: "%.1f", secs)]

        case .companionActionTapped(let action):
            return ["action": action]

        case .publishStarted(let jobId, let provider):
            return ["jobId": jobId.uuidString, "provider": provider]

        case .publishSucceeded(let jobId, let provider):
            return ["jobId": jobId.uuidString, "provider": provider]

        case .publishFailed(let jobId, let provider, let reason):
            return ["jobId": jobId.uuidString, "provider": provider, "reason": reason]

        case .improvementRequested(let jobId, let srcId):
            return ["jobId": jobId.uuidString, "sourceEntryId": srcId.uuidString]

        case .improvementApproved(let jobId, let delta):
            var p = ["jobId": jobId.uuidString]
            if let d = delta { p["scoreDelta"] = String(format: "%.2f", d) }
            return p

        case .improvementRejected(let jobId):
            return ["jobId": jobId.uuidString]

        case .versionRestored(let entryId):
            return ["entryId": entryId.uuidString]

        case .policyApplied(let jobId, let categories):
            return ["jobId": jobId.uuidString, "categories": categories]

        case .causalInsightComputed(let category, let causalEffect, let nTreated, let nControl):
            return [
                "category": category,
                "causalEffect": String(format: "%.2f", causalEffect),
                "nTreated": "\(nTreated)",
                "nControl": "\(nControl)"
            ]

        case .outcomeEvaluated(let jobId, let predicted, let actual, let error):
            return [
                "jobId": jobId.uuidString,
                "predictedImpact": String(format: "%.2f", predicted),
                "actualImpact": String(format: "%.2f", actual),
                "errorDelta": String(format: "%.2f", error)
            ]

        case .attentionDirectiveIssued(let section, let urgency):
            return ["section": section, "urgency": String(format: "%.2f", urgency)]
        }
    }

    func toRecord() -> TelemetryRecord {
        TelemetryRecord(id: UUID(), timestamp: .now, event: name, properties: properties)
    }
}

// MARK: - Service

@MainActor
final class TelemetryService: ObservableObject {

    static let shared = TelemetryService()

    @Published private(set) var records: [TelemetryRecord] = []

    private let maxRecords   = 10_000
    private var writeCount   = 0
    private let trimInterval = 100

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("telemetry.jsonl")
    }()

    private init() { records = loadFromDisk() }

    // MARK: - Public API

    func track(_ event: TelemetryEvent) {
        let record = event.toRecord()
        records.append(record)
        appendToDisk(record)
        writeCount += 1
        if writeCount % trimInterval == 0 { trimIfNeeded() }
    }

    // MARK: - Query interface

    func count(_ eventName: String, since: Date? = nil) -> Int {
        filtered(eventName, since: since).count
    }

    func records(for eventName: String, since: Date? = nil) -> [TelemetryRecord] {
        filtered(eventName, since: since)
    }

    func latest(_ eventName: String) -> TelemetryRecord? {
        records.last(where: { $0.event == eventName })
    }

    // MARK: - Derived metrics

    var totalWebsitesBuilt: Int {
        records.filter {
            $0.event == "agent_completed" && $0.properties["jobType"] == "Website Builder"
        }.count
    }

    var websiteBuildSuccessRate: Double {
        rate(completed: "agent_completed", started: "agent_started")
    }

    var averageBuildDurationSeconds: Double {
        let durations = records
            .filter { $0.event == "agent_completed" && $0.properties["jobType"] == "Website Builder" }
            .compactMap { Double($0.properties["durationSeconds"] ?? "") }
        return durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
    }

    var totalPublished: Int { count("publish_succeeded") }

    var publishSuccessRate: Double {
        rate(completed: "publish_succeeded", started: "publish_started")
    }

    var improvementAcceptanceRate: Double {
        rate(completed: "improvement_approved", started: "improvement_requested")
    }

    var companionActionTapRate: Double {
        rate(completed: "companion_action_tapped", started: "companion_shown")
    }

    var topCompanionAction: String? {
        let taps = records.filter { $0.event == "companion_action_tapped" }
        return Dictionary(grouping: taps, by: { $0.properties["action"] ?? "unknown" })
            .mapValues(\.count)
            .max(by: { $0.value < $1.value })?.key
    }

    // MARK: - Private helpers

    private func filtered(_ event: String, since: Date?) -> [TelemetryRecord] {
        let base = records.filter { $0.event == event }
        guard let since else { return base }
        return base.filter { $0.timestamp >= since }
    }

    private func rate(completed: String, started: String) -> Double {
        let s = Double(count(started)), c = Double(count(completed))
        return s > 0 ? min(c / s, 1.0) : 0
    }

    // MARK: - Persistence (JSONL — append-only, O(1) writes)

    private func loadFromDisk() -> [TelemetryRecord] {
        guard let data    = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return content
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { try? decoder.decode(TelemetryRecord.self, from: Data($0.utf8)) }
    }

    private func appendToDisk(_ record: TelemetryRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data    = try? encoder.encode(record),
              let line    = String(data: data, encoding: .utf8),
              let lineData = (line + "\n").data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(lineData)
            handle.closeFile()
        } else {
            try? lineData.write(to: fileURL, options: .atomic)
        }
    }

    private func trimIfNeeded() {
        guard records.count > maxRecords else { return }
        records = Array(records.suffix(maxRecords))
        rewriteDisk(records)
    }

    private func rewriteDisk(_ recs: [TelemetryRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let content = recs
            .compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let data = (content.isEmpty ? "" : content + "\n").data(using: .utf8) ?? Data()
        try? data.write(to: fileURL, options: .atomic)
    }
}
