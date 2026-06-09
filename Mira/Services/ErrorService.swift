import Foundation

// MARK: - Category

enum MiraErrorCategory: String, Codable, CaseIterable {
    case authentication  = "authentication"
    case authorization   = "authorization"
    case integration     = "integration"
    case network         = "network"
    case timeout         = "timeout"
    case rateLimit       = "rate_limit"
    case aiProvider      = "ai_provider"
    case agentService    = "agent_service"
    case filesystem      = "filesystem"
    case validation      = "validation"
    case unknown         = "unknown"

    var displayName: String {
        switch self {
        case .authentication: return "Authentication"
        case .authorization:  return "Authorization"
        case .integration:    return "Integration"
        case .network:        return "Network"
        case .timeout:        return "Timeout"
        case .rateLimit:      return "Rate Limit"
        case .aiProvider:     return "AI Provider"
        case .agentService:   return "Agent Service"
        case .filesystem:     return "Filesystem"
        case .validation:     return "Validation"
        case .unknown:        return "Unknown"
        }
    }
}

// MARK: - Recovery Action

struct RecoveryAction: Codable, Identifiable, Equatable {
    let id: UUID
    let label: String
    let actionTag: String
    let style: String

    init(label: String, tag: String, style: String = "primary") {
        self.id       = UUID()
        self.label    = label
        self.actionTag = tag
        self.style    = style
    }

    var companionSpec: CompanionActionSpec {
        switch actionTag {
        case "reconnect":    return .reconnect()
        case "retry":        return .retry()
        case "open_island":  return .openIsland()
        case "view_library": return .viewLibrary()
        default:
            let s: CompanionActionStyle = style == "primary" ? .primary : .secondary
            return CompanionActionSpec(label, style: s, tag: actionTag)
        }
    }
}

// MARK: - Resolution

struct ErrorResolution {
    let id: UUID
    let category: MiraErrorCategory
    let userMessage: String
    let recoverable: Bool
    let actions: [RecoveryAction]

    var companionActions: [CompanionActionSpec] {
        actions.map(\.companionSpec)
    }
}

// MARK: - Record (persisted to errors.jsonl)

struct ErrorRecord: Codable {
    let id: UUID
    let timestamp: Date
    let category: MiraErrorCategory
    let source: String
    let rawError: String
    let userMessage: String
    let recoverable: Bool
    let recoveryActions: [RecoveryAction]
    let jobId: UUID?
    var recoveryAttempt: RecoveryAttempt?
}

struct RecoveryAttempt: Codable {
    let action: String
    let attemptedAt: Date
    var succeeded: Bool?
    var resolvedAt: Date?
}

// MARK: - Service

@MainActor
final class ErrorService {
    static let shared = ErrorService()

    private(set) var records: [ErrorRecord] = []
    private let maxRecords = 5_000

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("errors.jsonl")
    }()

    private init() { records = loadFromDisk() }

    // MARK: - Public API

    @discardableResult
    func handle(_ message: String, source: String = "", jobId: UUID? = nil) -> ErrorResolution {
        let category    = classify(message)
        let userMessage = friendlyMessage(for: category, raw: message)
        let recoverable = isRecoverable(category)
        let actions     = recoveryActions(for: category)

        let record = ErrorRecord(
            id: UUID(),
            timestamp: .now,
            category: category,
            source: source,
            rawError: message,
            userMessage: userMessage,
            recoverable: recoverable,
            recoveryActions: actions,
            jobId: jobId
        )
        persist(record)

        return ErrorResolution(
            id: record.id,
            category: category,
            userMessage: userMessage,
            recoverable: recoverable,
            actions: actions
        )
    }

    @discardableResult
    func handle(_ error: Error, source: String = "", jobId: UUID? = nil) -> ErrorResolution {
        handle(error.localizedDescription, source: source, jobId: jobId)
    }

    func recordRecoveryAttempt(errorId: UUID, action: String) {
        guard let idx = records.firstIndex(where: { $0.id == errorId }) else { return }
        records[idx].recoveryAttempt = RecoveryAttempt(action: action, attemptedAt: .now)
        rewriteDisk()
    }

    func recordRecoveryOutcome(errorId: UUID, succeeded: Bool) {
        guard let idx = records.firstIndex(where: { $0.id == errorId }) else { return }
        records[idx].recoveryAttempt?.succeeded = succeeded
        records[idx].recoveryAttempt?.resolvedAt = .now
        rewriteDisk()
    }

    // MARK: - Query

    func errorCount(for category: MiraErrorCategory, since: Date? = nil) -> Int {
        records
            .filter { $0.category == category }
            .filter { record in since.map { record.timestamp >= $0 } ?? true }
            .count
    }

    var topCategory: MiraErrorCategory? {
        Dictionary(grouping: records, by: \.category)
            .mapValues(\.count)
            .max(by: { $0.value < $1.value })?.key
    }

    var recoverySuccessRate: Double {
        let attempted = records.compactMap(\.recoveryAttempt)
        guard !attempted.isEmpty else { return 0 }
        let succeeded = attempted.filter { $0.succeeded == true }.count
        return Double(succeeded) / Double(attempted.count)
    }

    // MARK: - Classification

    private func classify(_ raw: String) -> MiraErrorCategory {
        let s = raw.lowercased()

        if s.contains("agent service") || s.contains("npm start") ||
           s.contains("econnrefused") || s.contains("not running") { return .agentService }

        if s.contains("429") || s.contains("rate limit") ||
           s.contains("too many requests") { return .rateLimit }

        if s.contains("401") || s.contains("unauthorized") ||
           s.contains("api key") || s.contains("api_key") ||
           s.contains("invalid key") { return .authentication }

        if s.contains("403") || s.contains("forbidden") { return .authorization }

        if (s.contains("vercel") || s.contains("netlify") ||
            s.contains("github") || s.contains("composio")) &&
           (s.contains("token") || s.contains("connect") ||
            s.contains("not connected") || s.contains("expired")) { return .integration }

        if s.contains("timeout") || s.contains("timed out") { return .timeout }

        if s.contains("network") || s.contains("connection") ||
           s.contains("offline") || s.contains("unreachable") { return .network }

        if s.contains("anthropic") || s.contains("openai") ||
           s.contains("ai provider") { return .aiProvider }

        if s.contains("no such file") || s.contains("file not found") ||
           (s.contains("permission denied") && s.contains("file")) { return .filesystem }

        if s.contains("invalid") || s.contains("missing") ||
           s.contains("required") || s.contains("malformed") { return .validation }

        return .unknown
    }

    private func friendlyMessage(for category: MiraErrorCategory, raw: String) -> String {
        let s = raw.lowercased()
        switch category {
        case .integration:
            if s.contains("vercel")   { return "Vercel token expired or not connected" }
            if s.contains("netlify")  { return "Netlify token expired or not connected" }
            if s.contains("github")   { return "GitHub is not connected" }
            if s.contains("composio") { return "Composio integration unavailable" }
            return "Integration not connected"
        case .authentication:
            if s.contains("api key") || s.contains("api_key") { return "Claude API key is invalid" }
            return "Authorization expired — please reconnect"
        case .authorization:
            return "Access denied — check your account permissions"
        case .rateLimit:
            return "Rate limit reached — please wait a moment and retry"
        case .timeout:
            return "Request timed out"
        case .network:
            return "Network unavailable"
        case .aiProvider:
            return "AI provider unavailable — please retry"
        case .agentService:
            return "Agent service is not running"
        case .filesystem:
            return "File not found or inaccessible"
        case .validation, .unknown:
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 80 ? String(trimmed.prefix(77)) + "…" : trimmed
        }
    }

    private func isRecoverable(_ category: MiraErrorCategory) -> Bool {
        switch category {
        case .timeout, .network, .rateLimit, .aiProvider,
             .integration, .authentication: return true
        default: return false
        }
    }

    private func recoveryActions(for category: MiraErrorCategory) -> [RecoveryAction] {
        switch category {
        case .integration:
            return [
                RecoveryAction(label: "Reconnect", tag: "reconnect"),
                RecoveryAction(label: "Open Mira", tag: "open_island", style: "secondary"),
            ]
        case .authentication:
            return [
                RecoveryAction(label: "Open Settings", tag: "open_island"),
                RecoveryAction(label: "Retry",         tag: "retry", style: "secondary"),
            ]
        case .timeout, .network, .rateLimit, .aiProvider:
            return [
                RecoveryAction(label: "Retry",     tag: "retry"),
                RecoveryAction(label: "Open Mira", tag: "open_island", style: "secondary"),
            ]
        case .agentService:
            return [
                RecoveryAction(label: "Open Mira", tag: "open_island"),
            ]
        default:
            return [
                RecoveryAction(label: "Open Mira", tag: "open_island"),
            ]
        }
    }

    // MARK: - Persistence

    private func persist(_ record: ErrorRecord) {
        records.append(record)
        if records.count > maxRecords { records = Array(records.suffix(maxRecords)) }
        appendToDisk(record)
    }

    private func loadFromDisk() -> [ErrorRecord] {
        guard let data    = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return content
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { try? decoder.decode(ErrorRecord.self, from: Data($0.utf8)) }
    }

    private func appendToDisk(_ record: ErrorRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data     = try? encoder.encode(record),
              let line     = String(data: data, encoding: .utf8),
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

    private func rewriteDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let content = records
            .compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let data = (content.isEmpty ? "" : content + "\n").data(using: .utf8) ?? Data()
        try? data.write(to: fileURL, options: .atomic)
    }
}
