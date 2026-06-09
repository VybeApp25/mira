import Foundation

// MARK: - Health Finding Severity

enum HealthFindingSeverity: String, Codable {
    case critical, warning, suggestion
}

// MARK: - Health Finding

struct HealthFinding: Codable, Identifiable {
    let id: UUID
    let category: String
    let severity: HealthFindingSeverity
    let message: String

    init(category: String, severity: HealthFindingSeverity, message: String) {
        id = UUID()
        self.category = category
        self.severity = severity
        self.message = message
    }
}

// MARK: - Website Health Report

struct WebsiteHealthReport: Codable {
    let overallScore: Int
    let traffic: Int?
    let conversions: Int?
    let mobileUX: Int
    let seo: Int
    let accessibility: Int
    let findings: [HealthFinding]
    let analyzedAt: Date
    let analyzedVersion: Int
}

// MARK: - Output Type

enum OutputType: String, Codable, CaseIterable {
    case website  = "Website"
    case research = "Research"
    case document = "Document"
    case app      = "App"

    var icon: String {
        switch self {
        case .website:  return "globe"
        case .research: return "doc.text.magnifyingglass"
        case .document: return "doc.text"
        case .app:      return "app.badge"
        }
    }

    var folderName: String {
        switch self {
        case .website:  return "Websites"
        case .research: return "Research"
        case .document: return "Documents"
        case .app:      return "Apps"
        }
    }

    var agentName: String {
        switch self {
        case .website:  return "Website Builder Agent"
        case .research: return "Research Agent"
        case .document: return "Content Agent"
        case .app:      return "App Builder Agent"
        }
    }
}

// MARK: - Edit Message (conversation history within an output's detail view)

enum MessageRole: String, Codable { case user, assistant }

struct EditMessage: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    let role: MessageRole
    let content: String
    var linkedVersionId: UUID?   // set when this message triggered a version creation
}

// MARK: - Output Version (structural placeholder — enables version history without migration later)

struct OutputVersion: Identifiable {
    let id: UUID
    let createdAt: Date
    let label: String
    let filePath: String
    let sourceJobId: UUID?
    let editPrompt: String?        // the user's edit request that created this version
    let createdByAgent: String?    // e.g. "Website Builder Agent", "Website Editor Agent"
}

// MARK: - Output Entry

struct OutputEntry: Identifiable {
    let id: UUID
    let type: OutputType
    var name: String
    let primaryFilePath: String
    let outputDirectory: String
    var previewImagePath: String?
    let sourceJobId: UUID
    let createdAt: Date
    var metadata: [String: String]
    // Usage tracking
    var lastOpenedAt: Date?
    var openCount: Int
    var favorite: Bool
    // Version history
    var versions: [OutputVersion]
    // Conversational edit thread
    var editHistory: [EditMessage]
    // Compressed project history — regenerated every 3 versions when count >= 5
    var projectSummary: String?
    var summaryVersionCount: Int
    // Publishing
    var publishedUrl: String?
    var publishedAt: Date?
    var deploymentProvider: String?
    var deploymentStatus: String?    // "deploying", "live", "failed"
    // Health analysis
    var healthReport: WebsiteHealthReport?
    var analyticsProvider: String?   // "google_analytics", "plausible", "posthog"
    var analyticsPropertyId: String? // GA4 measurement ID or Plausible site ID

    var relativeTime: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        return "\(Int(diff / 86400))d ago"
    }
}

// MARK: - Codable (migration-safe: editPrompt and createdByAgent use decodeIfPresent)

extension OutputVersion: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, label, filePath, sourceJobId, editPrompt, createdByAgent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(UUID.self,   forKey: .id)
        createdAt      = try c.decode(Date.self,   forKey: .createdAt)
        label          = try c.decode(String.self, forKey: .label)
        filePath       = try c.decode(String.self, forKey: .filePath)
        sourceJobId    = try c.decodeIfPresent(UUID.self,   forKey: .sourceJobId)
        editPrompt     = try c.decodeIfPresent(String.self, forKey: .editPrompt)
        createdByAgent = try c.decodeIfPresent(String.self, forKey: .createdByAgent)
    }
}

extension OutputEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, type, name, primaryFilePath, outputDirectory
        case previewImagePath, sourceJobId, createdAt, metadata
        case lastOpenedAt, openCount, favorite, versions, editHistory
        case projectSummary, summaryVersionCount
        case publishedUrl, publishedAt, deploymentProvider, deploymentStatus
        case healthReport, analyticsProvider, analyticsPropertyId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = try c.decode(UUID.self,              forKey: .id)
        type             = try c.decode(OutputType.self,        forKey: .type)
        name             = try c.decode(String.self,            forKey: .name)
        primaryFilePath  = try c.decode(String.self,            forKey: .primaryFilePath)
        outputDirectory  = try c.decode(String.self,            forKey: .outputDirectory)
        previewImagePath = try c.decodeIfPresent(String.self,   forKey: .previewImagePath)
        sourceJobId      = try c.decode(UUID.self,              forKey: .sourceJobId)
        createdAt        = try c.decode(Date.self,              forKey: .createdAt)
        metadata         = try c.decode([String: String].self,  forKey: .metadata)
        lastOpenedAt         = try c.decodeIfPresent(Date.self,     forKey: .lastOpenedAt)
        openCount            = try c.decodeIfPresent(Int.self,      forKey: .openCount)          ?? 0
        favorite             = try c.decodeIfPresent(Bool.self,     forKey: .favorite)           ?? false
        versions             = try c.decodeIfPresent([OutputVersion].self,  forKey: .versions)   ?? []
        editHistory          = try c.decodeIfPresent([EditMessage].self,    forKey: .editHistory) ?? []
        projectSummary       = try c.decodeIfPresent(String.self,   forKey: .projectSummary)
        summaryVersionCount  = try c.decodeIfPresent(Int.self,      forKey: .summaryVersionCount) ?? 0
        publishedUrl         = try c.decodeIfPresent(String.self,             forKey: .publishedUrl)
        publishedAt          = try c.decodeIfPresent(Date.self,               forKey: .publishedAt)
        deploymentProvider   = try c.decodeIfPresent(String.self,             forKey: .deploymentProvider)
        deploymentStatus     = try c.decodeIfPresent(String.self,             forKey: .deploymentStatus)
        healthReport         = try c.decodeIfPresent(WebsiteHealthReport.self, forKey: .healthReport)
        analyticsProvider    = try c.decodeIfPresent(String.self,             forKey: .analyticsProvider)
        analyticsPropertyId  = try c.decodeIfPresent(String.self,             forKey: .analyticsPropertyId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,              forKey: .id)
        try c.encode(type,            forKey: .type)
        try c.encode(name,            forKey: .name)
        try c.encode(primaryFilePath, forKey: .primaryFilePath)
        try c.encode(outputDirectory, forKey: .outputDirectory)
        try c.encodeIfPresent(previewImagePath, forKey: .previewImagePath)
        try c.encode(sourceJobId,     forKey: .sourceJobId)
        try c.encode(createdAt,       forKey: .createdAt)
        try c.encode(metadata,        forKey: .metadata)
        try c.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
        try c.encode(openCount,            forKey: .openCount)
        try c.encode(favorite,             forKey: .favorite)
        try c.encode(versions,             forKey: .versions)
        try c.encode(editHistory,          forKey: .editHistory)
        try c.encodeIfPresent(projectSummary,    forKey: .projectSummary)
        try c.encode(summaryVersionCount,        forKey: .summaryVersionCount)
        try c.encodeIfPresent(publishedUrl,       forKey: .publishedUrl)
        try c.encodeIfPresent(publishedAt,        forKey: .publishedAt)
        try c.encodeIfPresent(deploymentProvider, forKey: .deploymentProvider)
        try c.encodeIfPresent(deploymentStatus,   forKey: .deploymentStatus)
        try c.encodeIfPresent(healthReport,       forKey: .healthReport)
        try c.encodeIfPresent(analyticsProvider,  forKey: .analyticsProvider)
        try c.encodeIfPresent(analyticsPropertyId, forKey: .analyticsPropertyId)
    }
}
