import Foundation

// MARK: - Attention Target

enum AttentionTarget: Equatable {
    case dashboardSection(String)
    case agentRailJob(UUID)
    case policyRecommendation(UUID)
    case outputEntry(UUID)
}

// MARK: - Attention Action

enum AttentionAction: String {
    case highlight
    case expand
    case badge
    case prioritize
}

// MARK: - Attention Directive

struct AttentionDirective: Identifiable {
    let id = UUID()
    let target: AttentionTarget
    let urgency: Double            // 0.0–1.0
    let reason: String
    let suggestedAction: AttentionAction
    let issuedAt: Date
    var expiresAt: Date?
}
