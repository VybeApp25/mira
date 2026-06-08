import Foundation

// MARK: - Job Status

enum AgentJobStatus: String, Codable, Equatable {
    case queued
    case running
    case waitingForInput
    case completed
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .queued:          return "Queued"
        case .running:         return "Running"
        case .waitingForInput: return "Waiting for Input"
        case .completed:       return "Completed"
        case .failed:          return "Failed"
        case .cancelled:       return "Cancelled"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

// MARK: - Job Type

enum AgentJobType: String, Codable, CaseIterable {
    case websiteBuilder    = "Website Builder"
    case appBuilder        = "App Builder"
    case deepResearch      = "Deep Research"
    case contentGeneration = "Content Generation"
    case dataExport        = "Data Export"
    case custom            = "Custom"

    var icon: String {
        switch self {
        case .websiteBuilder:    return "globe"
        case .appBuilder:        return "app.badge"
        case .deepResearch:      return "magnifyingglass.circle.fill"
        case .contentGeneration: return "doc.text.fill"
        case .dataExport:        return "arrow.down.doc.fill"
        case .custom:            return "bolt.fill"
        }
    }

    var defaultActions: [AgentJobAction] {
        switch self {
        case .websiteBuilder:
            return [
                AgentJobAction(title: "Open in Browser", icon: "safari",             identifier: "open_browser"),
                AgentJobAction(title: "Suggest Edits",   icon: "pencil",             identifier: "suggest_edits"),
                AgentJobAction(title: "Export Code",     icon: "arrow.down.doc",     identifier: "export_code"),
                AgentJobAction(title: "Duplicate",       icon: "doc.on.doc",         identifier: "duplicate"),
            ]
        case .deepResearch:
            return [
                AgentJobAction(title: "Open Report",          icon: "doc.text",                 identifier: "open_report"),
                AgentJobAction(title: "Create Summary",        icon: "list.bullet.rectangle",    identifier: "summarize"),
                AgentJobAction(title: "Export PDF",            icon: "arrow.down.doc",           identifier: "export_pdf"),
                AgentJobAction(title: "Create Presentation",  icon: "rectangle.on.rectangle",   identifier: "create_presentation"),
            ]
        case .appBuilder:
            return [
                AgentJobAction(title: "Open Project", icon: "folder",            identifier: "open_project"),
                AgentJobAction(title: "Run Preview",  icon: "play.circle",       identifier: "run_preview"),
                AgentJobAction(title: "Export Source", icon: "arrow.down.doc",   identifier: "export_source"),
            ]
        case .contentGeneration:
            return [
                AgentJobAction(title: "Copy Text",    icon: "doc.on.clipboard",  identifier: "copy_text"),
                AgentJobAction(title: "Export PDF",   icon: "arrow.down.doc",    identifier: "export_pdf"),
                AgentJobAction(title: "Open File",    icon: "doc",               identifier: "open_file"),
            ]
        default:
            return [
                AgentJobAction(title: "View Result", icon: "eye", identifier: "view_result"),
            ]
        }
    }

    // Detect job type from a plain-text user prompt
    static func detect(from prompt: String) -> AgentJobType {
        let lower = prompt.lowercased()
        if lower.contains("website") || lower.contains("site") || lower.contains("landing page") ||
           lower.contains("web app") || lower.contains("webpage") {
            return .websiteBuilder
        }
        if lower.contains("research") || lower.contains("investigate") ||
           lower.contains("deep dive") || lower.contains("analyze") {
            return .deepResearch
        }
        if lower.contains("write") || lower.contains("draft") || lower.contains("generate content") ||
           lower.contains("article") || lower.contains("blog post") {
            return .contentGeneration
        }
        if lower.contains("build app") || lower.contains("create app") || lower.contains("mobile app") {
            return .appBuilder
        }
        return .custom
    }
}

// MARK: - Step

struct AgentJobStep: Identifiable, Codable {
    let id: UUID
    let title: String
    var status: AgentJobStatus
    var startedAt: Date?
    var completedAt: Date?
    var log: String?

    init(title: String) {
        self.id = UUID()
        self.title = title
        self.status = .queued
    }
}

// MARK: - Action (contextual buttons shown after completion)

struct AgentJobAction: Identifiable, Codable {
    let id: UUID
    let title: String
    let icon: String
    let identifier: String

    init(title: String, icon: String, identifier: String) {
        self.id = UUID()
        self.title = title
        self.icon = icon
        self.identifier = identifier
    }
}

// MARK: - Result

struct AgentJobResult: Codable {
    let summary: String
    let outputPath: String?
    let previewImagePath: String?
    var metadata: [String: String]
}

// MARK: - AgentJob

struct AgentJob: Identifiable, Codable {
    let id: UUID
    let type: AgentJobType
    let prompt: String
    var status: AgentJobStatus
    var progress: Double            // 0.0–1.0
    var currentStep: String
    var steps: [AgentJobStep]
    var result: AgentJobResult?
    var errorMessage: String?
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var estimatedDuration: TimeInterval

    init(type: AgentJobType, prompt: String) {
        self.id = UUID()
        self.type = type
        self.prompt = prompt
        self.status = .queued
        self.progress = 0
        self.currentStep = "Queued"
        self.steps = []
        self.result = nil
        self.errorMessage = nil
        self.createdAt = Date()
        self.startedAt = nil
        self.completedAt = nil
        self.estimatedDuration = 60
    }

    var timeElapsed: TimeInterval? {
        guard let start = startedAt else { return nil }
        return (completedAt ?? Date()).timeIntervalSince(start)
    }

    var estimatedTimeRemaining: TimeInterval? {
        guard status == .running, let elapsed = timeElapsed else { return nil }
        let remaining = estimatedDuration * (1 - progress) - (elapsed - estimatedDuration * progress)
        return remaining > 0 ? remaining : nil
    }

    var relativeTime: String {
        let date = completedAt ?? startedAt ?? createdAt
        let diff = Date().timeIntervalSince(date)
        if diff < 60   { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        return "\(Int(diff / 86400))d ago"
    }

    var actions: [AgentJobAction] { type.defaultActions }
}
