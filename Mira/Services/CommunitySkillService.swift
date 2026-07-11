import Foundation

// MARK: - CommunitySkillService (Gap B Phase 3)
//
// Client for the community skills catalog: browse approved skills (public
// `skills-catalog` fn), install one locally (writes a user skill — NEVER
// auto-activated), and publish a local user skill (`skills-publish` fn, which
// runs the Claude moderation pass server-side and returns the verdict).
// Text-only; see docs/specs/community-skills-moderation.md.

struct CommunitySkill: Identifiable, Codable, Equatable {
    var id: String { slug }
    let slug: String
    let name: String
    let tagline: String
    let category: String
    let icon: String
    let body: String
    let author_handle: String?
    let downloads: Int?

    /// Reconstruct a SKILL.md the local loader can validate + install.
    var skillMarkdown: String {
        """
        ---
        name: \(slug)
        title: \(name)
        tagline: \(tagline)
        category: \(category)
        icon: \(icon)
        ---
        \(body)
        """
    }
}

struct PublishOutcome {
    let status: String   // approved | pending | rejected
    let reason: String
    let slug: String
}

@MainActor
final class CommunitySkillService: ObservableObject {
    static let shared = CommunitySkillService()
    private init() {}

    enum ServiceError: LocalizedError {
        case notSignedIn
        case server(String)
        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in to publish a skill."
            case .server(let m): return m
            }
        }
    }

    private var base: String { "\(AppSecrets.supabaseURL)/functions/v1" }

    // MARK: - Browse (public)

    func fetchCatalog(query: String = "") async throws -> [CommunitySkill] {
        var comps = URLComponents(string: "\(base)/skills-catalog")!
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { comps.queryItems = [URLQueryItem(name: "q", value: q)] }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServiceError.server("Couldn't load the community catalog.")
        }
        struct Wrap: Decodable { let skills: [CommunitySkill] }
        return (try? JSONDecoder().decode(Wrap.self, from: data))?.skills ?? []
    }

    // MARK: - Install (local, never auto-activated)

    /// Writes the skill into the local user library and returns its id. Does NOT
    /// activate it — community skills are unreviewed by Mira, so activation stays
    /// an explicit user action.
    @discardableResult
    func install(_ skill: CommunitySkill) throws -> String {
        try MiraSkillLoader.shared.createUserSkill(markdown: skill.skillMarkdown)
    }

    // MARK: - Publish (authed → server moderation)

    func publish(markdown: String) async throws -> PublishOutcome {
        let jwt = SupabaseService.cachedAccessToken
        guard !jwt.isEmpty else { throw ServiceError.notSignedIn }

        let url = URL(string: "\(base)/skills-publish")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let markdown: String }
        req.httpBody = try JSONEncoder().encode(Body(markdown: markdown))

        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let detail = (obj["detail"] as? String) ?? (obj["error"] as? String) ?? "Publish failed."
            throw ServiceError.server(detail)
        }
        return PublishOutcome(
            status: obj["status"] as? String ?? "pending",
            reason: obj["reason"] as? String ?? "",
            slug:   obj["slug"] as? String ?? "")
    }
}
