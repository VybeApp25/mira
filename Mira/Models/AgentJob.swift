import Foundation

// MARK: - Job Status

enum AgentJobStatus: String, Codable, Equatable {
    case queued
    case preparing
    case reading
    case running
    case writing
    case waitingForInput
    case waitingForConfirmation
    case waitingForVariantSelection
    case blockedPermission
    case blockedTool
    case completed
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .queued:                 return "Queued"
        case .preparing:              return "Preparing"
        case .reading:                return "Reading"
        case .running:                return "Running"
        case .writing:                return "Writing"
        case .waitingForInput:              return "Waiting for Input"
        case .waitingForConfirmation:       return "Awaiting Approval"
        case .waitingForVariantSelection:   return "Awaiting Selection"
        case .blockedPermission:            return "Blocked — Permission"
        case .blockedTool:            return "Blocked — Tool"
        case .completed:              return "Completed"
        case .failed:                 return "Failed"
        case .cancelled:              return "Cancelled"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    var isBlocked: Bool {
        self == .blockedPermission || self == .blockedTool
    }

    var isActive: Bool {
        switch self {
        case .queued, .preparing, .reading, .running, .writing: return true
        default: return false
        }
    }
}

// MARK: - Risk Level

enum RiskLevel: String, Codable {
    case low
    case medium
    case high

    var displayName: String {
        switch self {
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    var icon: String {
        switch self {
        case .low:    return "checkmark.shield"
        case .medium: return "exclamationmark.shield"
        case .high:   return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Confirmation Request

struct ConfirmationRequest: Codable, Identifiable {
    let id: UUID
    let title: String
    let summary: String
    let riskLevel: RiskLevel
    let approveLabel: String
    let denyLabel: String
    let generatedAt: Date

    init(title: String, summary: String, riskLevel: RiskLevel,
         approveLabel: String = "Approve", denyLabel: String = "Deny") {
        self.id = UUID()
        self.title = title
        self.summary = summary
        self.riskLevel = riskLevel
        self.approveLabel = approveLabel
        self.denyLabel = denyLabel
        self.generatedAt = Date()
    }
}

// MARK: - Variant Option (Studio mode — HTML + name only; previews held in AgentJobStore memory)

struct VariantOption: Codable, Identifiable {
    let id: UUID
    let name: String
    let html: String

    init(name: String, html: String) {
        self.id = UUID()
        self.name = name
        self.html = html
    }
}

// MARK: - Approval Decision (audit trail, persisted)

struct ApprovalDecision: Codable {
    let approved: Bool
    let timestamp: Date
    let userReason: String?
}

// MARK: - Website Build Mode

enum WebsiteBuildMode: String, Codable, CaseIterable {
    case fast       = "Fast"
    case pro        = "Pro"
    case studio     = "Studio"
    case multiAgent = "Multi-Agent"

    var icon: String {
        switch self {
        case .fast:       return "bolt.fill"
        case .pro:        return "sparkles"
        case .studio:     return "wand.and.stars"
        case .multiAgent: return "person.3.fill"
        }
    }

    var tagline: String {
        switch self {
        case .fast:       return "~1 min"
        case .pro:        return "~3 min"
        case .studio:     return "~7 min"
        case .multiAgent: return "~10 min"
        }
    }

    var estimatedDuration: TimeInterval {
        switch self {
        case .fast:       return 50
        case .pro:        return 180
        case .studio:     return 420
        case .multiAgent: return 600
        }
    }

    var requiresReferences: Bool { self == .studio }
    var runsQualityPass: Bool    { self != .fast }
    var runsTwoPasses: Bool      { self == .studio }
    var runReferenceAnalysis: Bool { self != .fast }
    var runsRepairPass: Bool     { self == .pro || self == .multiAgent }
}

// MARK: - Job Type

enum AgentJobType: String, Codable, CaseIterable {
    case websiteBuilder      = "Website Builder"
    case websiteEdit         = "Website Edit"
    case websiteImprovement  = "Website Improvement"
    case websiteHealth       = "Website Health"
    case publishWebsite      = "Publish Website"
    case appBuilder          = "App Builder"
    case deepResearch        = "Deep Research"
    case contentGeneration   = "Content Generation"
    case dataExport          = "Data Export"
    case custom              = "Custom"

    var icon: String {
        switch self {
        case .websiteBuilder:     return "globe"
        case .websiteEdit:        return "wand.and.sparkles"
        case .websiteImprovement: return "star.leadinghalf.filled"
        case .websiteHealth:      return "heart.text.square.fill"
        case .publishWebsite:     return "paperplane.fill"
        case .appBuilder:         return "app.badge"
        case .deepResearch:       return "magnifyingglass.circle.fill"
        case .contentGeneration:  return "doc.text.fill"
        case .dataExport:         return "arrow.down.doc.fill"
        case .custom:             return "bolt.fill"
        }
    }

    var defaultActions: [AgentJobAction] {
        switch self {
        case .websiteBuilder:
            return [
                AgentJobAction(title: "Open in Browser",  icon: "safari",                       identifier: "open_browser"),
                AgentJobAction(title: "Improve Website",  icon: "star.leadinghalf.filled",       identifier: "improve_website"),
                AgentJobAction(title: "Suggest Edits",    icon: "pencil",                       identifier: "suggest_edits"),
                AgentJobAction(title: "Export Code",      icon: "arrow.down.doc",               identifier: "export_code"),
            ]
        case .websiteImprovement:
            return [
                AgentJobAction(title: "Open Website",    icon: "globe",    identifier: "open_browser"),
                AgentJobAction(title: "View in Library", icon: "folder",   identifier: "open_project"),
            ]
        case .websiteHealth:
            return [
                AgentJobAction(title: "View Website",    icon: "globe",    identifier: "open_browser"),
                AgentJobAction(title: "View in Library", icon: "folder",   identifier: "open_project"),
            ]
        case .websiteEdit:
            return [
                AgentJobAction(title: "Open Website",    icon: "globe",              identifier: "open_browser"),
                AgentJobAction(title: "View in Library", icon: "folder",             identifier: "open_project"),
            ]
        case .publishWebsite:
            return [
                AgentJobAction(title: "Open Live Site", icon: "safari.fill",        identifier: "open_live_site"),
                AgentJobAction(title: "Copy URL",        icon: "doc.on.clipboard",   identifier: "copy_url"),
                AgentJobAction(title: "Republish",       icon: "arrow.clockwise",    identifier: "republish"),
            ]
        case .deepResearch:
            return [
                AgentJobAction(title: "Open Report",         icon: "doc.text",               identifier: "open_report"),
                AgentJobAction(title: "Create Summary",      icon: "list.bullet.rectangle",  identifier: "summarize"),
                AgentJobAction(title: "Export PDF",          icon: "arrow.down.doc",         identifier: "export_pdf"),
                AgentJobAction(title: "Create Presentation", icon: "rectangle.on.rectangle", identifier: "create_presentation"),
            ]
        case .appBuilder:
            return [
                AgentJobAction(title: "Open Project",  icon: "folder",          identifier: "open_project"),
                AgentJobAction(title: "Run Preview",   icon: "play.circle",     identifier: "run_preview"),
                AgentJobAction(title: "Export Source", icon: "arrow.down.doc",  identifier: "export_source"),
            ]
        case .contentGeneration:
            return [
                AgentJobAction(title: "Copy Text",  icon: "doc.on.clipboard", identifier: "copy_text"),
                AgentJobAction(title: "Export PDF", icon: "arrow.down.doc",   identifier: "export_pdf"),
                AgentJobAction(title: "Open File",  icon: "doc",              identifier: "open_file"),
            ]
        default:
            return [
                AgentJobAction(title: "View Result", icon: "eye", identifier: "view_result"),
            ]
        }
    }

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

// MARK: - Action

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

// MARK: - Build Readiness

struct BuildReadiness: Codable {
    let score: Double
    let missingRequirements: [String]
    let assumptions: [String]
    let summary: String

    var shouldAsk: Bool   { score < 70 }
    var hasWarnings: Bool { score >= 70 && score < 90 }
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
    var progress: Double
    var currentStep: String
    var steps: [AgentJobStep]
    var result: AgentJobResult?
    var errorMessage: String?
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var estimatedDuration: TimeInterval
    var buildReadiness: BuildReadiness?
    var userProvidedInfo: String?
    var confirmationRequest: ConfirmationRequest?
    var approvalDecision: ApprovalDecision?
    var buildMode: WebsiteBuildMode?
    var referenceImagePaths: [String]
    var variantOptions: [VariantOption]?
    var editSourceEntryId: UUID?
    var publishTarget: String?       // e.g. "vercel", "netlify", "github" — set for publishWebsite jobs
    var errorCategory: MiraErrorCategory?

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
        self.errorCategory = nil
        self.createdAt = Date()
        self.startedAt = nil
        self.completedAt = nil
        self.estimatedDuration = 60
        self.confirmationRequest = nil
        self.approvalDecision = nil
        self.buildMode = nil
        self.referenceImagePaths = []
        self.variantOptions = nil
        self.editSourceEntryId = nil
        self.publishTarget = nil
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
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        return "\(Int(diff / 86400))d ago"
    }

    var actions: [AgentJobAction] { type.defaultActions }
}
