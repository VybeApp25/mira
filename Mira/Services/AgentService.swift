import Foundation

struct AgentResponse: Decodable {
    let reply: String
    let toolsUsed: [String]
    let requiresConfirmation: PendingAction?
}

struct PendingAction: Decodable {
    let toolName: String
    let description: String
    let params: [String: AnyCodable]
}

struct ConfirmResult: Decodable {
    let success: Bool
    let result: AnyCodable?
}

// Thin wrapper so arbitrary JSON values survive Codable
struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let a = try? c.decode([AnyCodable].self) { value = a.map(\.value) }
        else if let o = try? c.decode([String: AnyCodable].self) { value = o.mapValues(\.value) }
        else { value = NSNull() }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let s as String: try c.encode(s)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let b as Bool: try c.encode(b)
        default: try c.encodeNil()
        }
    }
}

@MainActor
class AgentService: ObservableObject {
    static let shared = AgentService()

    private let base = URL(string: "http://127.0.0.1:4242")!

    // Composio entity ID — the per-user identity Composio isolates connected
    // accounts (Gmail/Slack/…) under. This MUST be unique per user, or everyone
    // shares one entity and can see each other's connections. We use the signed-in
    // Supabase user id; only signed-out/dev falls back to a manual override or
    // "default". NOTE: changing identity changes the entity, so accounts connected
    // under a prior entity (e.g. the old shared "default") need reconnecting.
    var userId: String {
        if let uid = SupabaseService.shared.session?.userId, !uid.isEmpty { return uid }
        return UserDefaults.standard.string(forKey: "mira_composio_entity") ?? "default"
    }

    var isRunning: Bool = false

    func checkHealth() async -> Bool {
        guard let req = request("GET", path: "/health") else { return false }
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    /// `accessToken` is the signed-in user's Supabase JWT. The sidecar reaches
    /// Anthropic through Mira's anthropic-proxy edge function using this token —
    /// no provider key is sent (or shipped in the client) anymore.
    func run(prompt: String, accessToken: String) async throws -> AgentResponse {
        var req = try post("/agent/run", body: [
            "prompt": prompt,
            "userId": userId,
            "accessToken": accessToken,
        ])
        req.timeoutInterval = 60
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(AgentResponse.self, from: data)
    }

    func confirm(action: PendingAction) async throws -> String {
        let paramsDict = action.params.mapValues { $0.value }
        let req = try post("/agent/confirm", body: [
            "toolName": action.toolName,
            "userId": userId,
            "params": paramsDict,
            "accessToken": SupabaseService.cachedAccessToken,
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        let result = try JSONDecoder().decode(ConfirmResult.self, from: data)
        return result.success ? "Done — \(action.description) complete." : "Something went wrong."
    }

    func connections() async throws -> [String] {
        guard var comps = URLComponents(url: base.appendingPathComponent("connections"), resolvingAgainstBaseURL: false) else {
            throw AgentError.badURL
        }
        comps.queryItems = [URLQueryItem(name: "userId", value: userId)]
        guard let url = comps.url else { throw AgentError.badURL }
        let (data, _) = try await URLSession.shared.data(for: authedGET(url))
        struct Resp: Decodable { let connected: [String] }
        return (try? JSONDecoder().decode(Resp.self, from: data))?.connected ?? []
    }

    struct ConnectionStatus: Decodable {
        let slug:   String
        let status: String   // ACTIVE | EXPIRED | FAILED | INITIATED | ...
        var isHealthy: Bool { status == "ACTIVE" }
    }

    /// Per-account health for every connected app (any status, not just ACTIVE) —
    /// lets the UI surface expired/revoked tokens with a Reconnect action.
    func connectionStatuses() async throws -> [ConnectionStatus] {
        guard var comps = URLComponents(url: base.appendingPathComponent("connections/status"), resolvingAgainstBaseURL: false) else {
            throw AgentError.badURL
        }
        comps.queryItems = [URLQueryItem(name: "userId", value: userId)]
        guard let url = comps.url else { throw AgentError.badURL }
        let (data, _) = try await URLSession.shared.data(for: authedGET(url))
        struct Resp: Decodable { let statuses: [ConnectionStatus] }
        return (try? JSONDecoder().decode(Resp.self, from: data))?.statuses ?? []
    }

    func disconnect(_ app: String) async throws {
        var req = try post("/disconnect/\(app)", body: ["userId": userId])
        req.timeoutInterval = 15
        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw AgentError.serviceDown
        }
    }

    func connectAppURL(_ app: String) async throws -> URL {
        guard var comps = URLComponents(url: base.appendingPathComponent("connect/\(app)"), resolvingAgainstBaseURL: false) else {
            throw AgentError.badURL
        }
        comps.queryItems = [URLQueryItem(name: "userId", value: userId)]
        guard let url = comps.url else { throw AgentError.badURL }
        let (data, _) = try await URLSession.shared.data(for: authedGET(url))
        struct Resp: Decodable { let url: String }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        guard let connectURL = URL(string: resp.url) else { throw AgentError.badURL }
        return connectURL
    }

    // MARK: - Helpers

    private func request(_ method: String, path: String) -> URLRequest? {
        guard let url = URL(string: path, relativeTo: base) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        return r
    }

    /// GET request carrying the signed-in user's Supabase JWT. The sidecar
    /// forwards it to the composio-proxy edge function, which holds the real
    /// Composio key — so no provider key ships in the client.
    private func authedGET(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.setValue("Bearer \(SupabaseService.cachedAccessToken)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func post(_ path: String, body: [String: Any]) throws -> URLRequest {
        guard var req = request("POST", path: path) else { throw AgentError.badURL }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }
}

enum AgentError: LocalizedError {
    case badURL
    case serviceDown

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid URL"
        case .serviceDown: return "Agent service not running. Start it with: cd Mira/AgentService && npm start"
        }
    }
}
