import Foundation

// MARK: - RecommendationEngine
//
// Synthesizes at most two proactive, personalized agent recommendations from
// local signals — the app-usage digest (opt-in), connected integrations, active
// skills, and known user preferences — via a single Claude call. Phase 1 is
// manual ("Suggest agents now"); Phase 2 wires this to a twice-daily
// BackgroundScheduler tick. See docs/specs/heyclicky-parity-proactive-and-skills.md.

@MainActor
final class RecommendationEngine: ObservableObject {
    static let shared = RecommendationEngine()
    private init() {}

    @Published private(set) var isGenerating = false
    @Published var lastError: String?

    func generateNow(apiKey: String) async {
        guard !isGenerating else { return }
        isGenerating = true
        lastError = nil
        defer { isGenerating = false }

        let context = buildContext()
        do {
            let service = ClaudeService(apiKey: apiKey)
            let recs = try await service.recommendAgents(context: context)
            RecommendationStore.shared.replacePending(with: recs)
            if recs.isEmpty { lastError = "No strong suggestions right now — try again after using your Mac a bit more." }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// All local. Only the aggregated result is sent to the model.
    private func buildContext() -> String {
        var parts: [String] = []

        if UsageLogService.shared.isEnabled {
            let digest = UsageLogService.shared.digest()
            if !digest.isEmpty {
                parts.append("Apps the user works in most (last 7 days, aggregated):\n\(digest)")
            }
        }

        let integrations = IntegrationContextService.cachedContext
        if !integrations.isEmpty {
            parts.append("Connected integrations & tools:\n\(integrations)")
        }

        let skills = SkillStore.cachedContext
        if !skills.isEmpty {
            parts.append("Skills the user has activated:\n\(skills)")
        }

        let knowledge = UserKnowledgeStore.cachedContext
        if !knowledge.isEmpty {
            parts.append("Known preferences & profile:\n\(knowledge)")
        }

        return parts.joined(separator: "\n\n")
    }
}
