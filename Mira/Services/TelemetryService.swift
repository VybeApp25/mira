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

    // Point-and-Ask guidance funnel. `id` correlates the request with its
    // outcome and any later acted-on click. Transcript content is NEVER stored —
    // only its length — so evidence collection can't leak what the user said.
    case guidanceRequested(id: UUID, transcriptChars: Int)
    case guidanceLocated(id: UUID, nx: Double, ny: Double, display: String)
    case guidanceNoElement(id: UUID)
    case guidanceFailed(id: UUID, reason: String)
    case guidanceActedOn(id: UUID, distancePt: Double, afterSeconds: Double)

    // Teaching engine learning funnel (instructed → completed → retained).
    // `groundedBy` records HOW completion was established — observation vs the
    // user saying so — so mastery is never credited to an unobserved step.
    case lessonStarted(skillId: String, totalSteps: Int)
    case stepInstructed(skillId: String, stepId: String)
    // Did the ring actually land? Recorded for EVERY ringed step so a silent
    // mis-ground is never invisible (meta-invariant: wrong-but-invisible →
    // forbidden). `grounded=false` is the ask-path fallback. Also the honest
    // signal for the "Unverified" badge and the instructed→attempted funnel.
    case stepGrounded(skillId: String, stepId: String, grounded: Bool, source: String, confidence: Double)
    // Opt-in "guide my cursor": Mira glided the pointer to a grounded target.
    // Recorded so a pointer move is never an unobserved action (Mira never clicks).
    case stepCursorGuided(skillId: String, stepId: String)
    // Autonomous outcome verification: did the auto-click visibly change the screen?
    // result = verified | retried | unverified. The honest signal behind self-correction.
    case stepOutcome(skillId: String, stepId: String, result: String)
    case stepCompleted(skillId: String, stepId: String, groundedBy: String)
    // A "Done"/"Skip" tap was ignored because its backing event was synthesized
    // and posted by another process, not a genuine human action. Recorded so the
    // honesty guard is never silent (an unrecorded guard is not an invariant).
    case stepConfirmRejected(skillId: String, stepId: String, reason: String)
    case stepFailed(skillId: String, stepId: String, reason: String)
    case lessonCompleted(skillId: String, completedSteps: Int, totalSteps: Int)

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
        case .guidanceRequested:          return "guidance_requested"
        case .guidanceLocated:            return "guidance_located"
        case .guidanceNoElement:          return "guidance_no_element"
        case .guidanceFailed:             return "guidance_failed"
        case .guidanceActedOn:            return "guidance_acted_on"
        case .lessonStarted:              return "lesson_started"
        case .stepInstructed:             return "step_instructed"
        case .stepGrounded:               return "step_grounded"
        case .stepCursorGuided:           return "step_cursor_guided"
        case .stepOutcome:                return "step_outcome"
        case .stepCompleted:              return "step_completed"
        case .stepConfirmRejected:        return "step_confirm_rejected"
        case .stepFailed:                 return "step_failed"
        case .lessonCompleted:            return "lesson_completed"
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

        case .guidanceRequested(let id, let chars):
            return ["id": id.uuidString, "transcriptChars": "\(chars)"]

        case .guidanceLocated(let id, let nx, let ny, let display):
            return ["id": id.uuidString,
                    "nx": String(format: "%.4f", nx),
                    "ny": String(format: "%.4f", ny),
                    "display": display]

        case .guidanceNoElement(let id):
            return ["id": id.uuidString]

        case .guidanceFailed(let id, let reason):
            return ["id": id.uuidString, "reason": reason]

        case .guidanceActedOn(let id, let distancePt, let afterSeconds):
            return ["id": id.uuidString,
                    "distancePt": String(format: "%.1f", distancePt),
                    "afterSeconds": String(format: "%.2f", afterSeconds)]

        case .lessonStarted(let skillId, let total):
            return ["skillId": skillId, "totalSteps": "\(total)"]

        case .stepInstructed(let skillId, let stepId):
            return ["skillId": skillId, "stepId": stepId]

        case .stepGrounded(let skillId, let stepId, let grounded, let source, let confidence):
            return ["skillId": skillId, "stepId": stepId, "grounded": grounded ? "true" : "false",
                    "source": source, "confidence": String(format: "%.2f", confidence)]

        case .stepCursorGuided(let skillId, let stepId):
            return ["skillId": skillId, "stepId": stepId]

        case .stepOutcome(let skillId, let stepId, let result):
            return ["skillId": skillId, "stepId": stepId, "result": result]

        case .stepCompleted(let skillId, let stepId, let groundedBy):
            return ["skillId": skillId, "stepId": stepId, "groundedBy": groundedBy]

        case .stepConfirmRejected(let skillId, let stepId, let reason):
            return ["skillId": skillId, "stepId": stepId, "reason": reason]

        case .stepFailed(let skillId, let stepId, let reason):
            return ["skillId": skillId, "stepId": stepId, "reason": reason]

        case .lessonCompleted(let skillId, let completed, let total):
            return ["skillId": skillId, "completedSteps": "\(completed)", "totalSteps": "\(total)"]
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
