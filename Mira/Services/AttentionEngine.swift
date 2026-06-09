import Foundation

// MARK: - Attention Engine
//
// Translates PolicyRecommendations into actionable UI directives.
// Views observe this service to know which sections to highlight, badge, or expand.

@MainActor
final class AttentionEngine: ObservableObject {
    static let shared = AttentionEngine()

    @Published private(set) var directives: [AttentionDirective] = []

    private init() {}

    // MARK: - Update from recommendations

    func update(from recommendations: [PolicyRecommendation]) {
        pruneExpired()

        var newDirectives: [AttentionDirective] = []

        for rec in recommendations {
            if rec.expectedImpact > 1.0 {
                let urgency = min(rec.expectedImpact / 5.0, 1.0)
                let directive = AttentionDirective(
                    target: .dashboardSection("Recommended Actions"),
                    urgency: urgency,
                    reason: "\(rec.category): expected +\(String(format: "%.1f", rec.expectedImpact)) pts",
                    suggestedAction: .highlight,
                    issuedAt: Date(),
                    expiresAt: Date().addingTimeInterval(3600) // 1 hour TTL
                )
                newDirectives.append(directive)
            }

            if rec.confidence == .high || rec.confidence == .medium {
                let causalDirective = AttentionDirective(
                    target: .dashboardSection("Causal Insights"),
                    urgency: min(rec.expectedImpact / 8.0, 0.9),
                    reason: "\(rec.category) has strong causal evidence",
                    suggestedAction: .badge,
                    issuedAt: Date(),
                    expiresAt: Date().addingTimeInterval(7200) // 2 hour TTL
                )
                newDirectives.append(causalDirective)
            }
        }

        // Replace old directives with new set
        directives = newDirectives
        TelemetryService.shared.track(.attentionDirectiveIssued(
            section: "Recommended Actions",
            urgency: newDirectives.map(\.urgency).max() ?? 0.0
        ))
    }

    // MARK: - Query helpers

    func shouldHighlight(_ section: String) -> Bool {
        directives.contains { $0.target == .dashboardSection(section) && $0.urgency > 0.4 }
    }

    func urgency(for section: String) -> Double {
        directives
            .filter { $0.target == .dashboardSection(section) }
            .map(\.urgency)
            .max() ?? 0.0
    }

    func prioritizedJobs(_ jobs: [AgentJob]) -> [AgentJob] {
        let urgentJobIds = directives
            .compactMap { directive -> UUID? in
                if case .agentRailJob(let id) = directive.target { return id }
                return nil
            }
        var sorted = jobs
        sorted.sort { a, b in
            let aUrgency = urgentJobIds.contains(a.id) ? 1.0 : 0.0
            let bUrgency = urgentJobIds.contains(b.id) ? 1.0 : 0.0
            return aUrgency > bUrgency
        }
        return sorted
    }

    func acknowledge(_ directiveId: UUID) {
        directives.removeAll { $0.id == directiveId }
    }

    func pruneExpired() {
        let now = Date()
        directives.removeAll { d in
            guard let exp = d.expiresAt else { return false }
            return exp < now
        }
    }
}
