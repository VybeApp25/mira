import Foundation
import Combine

// MARK: - Quota service (autonomy #3)
//
// The autonomy meter unit is "autonomous task runs / month". This is the client
// front for the SERVER-AUTHORITATIVE quota: `consume()` calls the Supabase
// `consume_task_run` RPC, which atomically checks the month's count against the
// per-tier limit derived from profiles.plan and either records the run or denies
// it. The server is the source of truth — a tampered client can't raise its own
// limit (the limit lives in SQL, keyed on the Stripe-updated plan).
//
// Offline / signed-out fallback: enforce locally via TaskRunLedger +
// EntitlementService.plan.monthlyTaskRunQuota so autonomy still works without a
// connection. KNOWN GAP: runs made while offline are NOT reconciled to the
// server, so offline is a soft escape hatch on the cap — acceptable pre-launch,
// tighten when it matters. See project_mira_autonomy_direction.

@MainActor
final class QuotaService: ObservableObject {
    static let shared = QuotaService()
    private init() {}

    struct Decision {
        var allowed: Bool
        var used: Int
        var limit: Int        // -1 = uncapped
        var remaining: Int    // -1 = uncapped
        var plan: String
        var offline: Bool
    }

    // Published "tasks left" state for the UI to bind to.
    @Published private(set) var used: Int = 0
    @Published private(set) var limit: Int = -1
    @Published private(set) var remaining: Int = -1
    @Published private(set) var planName: String = "Free"
    @Published private(set) var lastWasOffline = false

    var tasksLeftText: String {
        if limit < 0 { return "Unlimited tasks" }
        return "\(max(remaining, 0)) of \(limit) tasks left this month"
    }

    private struct RPCResult: Decodable {
        let allowed: Bool?
        let used: Int?
        let limit: Int?
        let remaining: Int?
        let plan: String?
        let error: String?
    }

    // MARK: - Consume (gate + record, atomic on the server)

    @discardableResult
    func consume(path: String, success: Bool = true, cost: Int = 0) async -> Decision {
        if SupabaseService.shared.isSignedIn {
            await SupabaseService.shared.ensureFreshToken()
            do {
                let body = try JSONSerialization.data(withJSONObject: [
                    "p_path": path, "p_success": success, "p_cost": cost
                ])
                let data = try await SupabaseService.shared.authedRequest(
                    path: "/rest/v1/rpc/consume_task_run", method: "POST", body: body)
                let r = try JSONDecoder().decode(RPCResult.self, from: data)
                let d = Decision(allowed: r.allowed ?? false,
                                 used: r.used ?? 0,
                                 limit: r.limit ?? -1,
                                 remaining: r.remaining ?? -1,
                                 plan: (r.plan ?? "free").capitalized,
                                 offline: false)
                apply(d)
                return d
            } catch {
                // Network/decoding/auth failure → fall through to local.
            }
        }
        return consumeOffline(path: path, success: success)
    }

    private func consumeOffline(path: String, success: Bool) -> Decision {
        let plan  = EntitlementService.shared.plan
        let limit = plan.monthlyTaskRunQuota
        let used  = TaskRunLedger.shared.runsThisMonth
        let allowed = used < limit
        if allowed { TaskRunLedger.shared.record(task: path, path: path, success: success) }
        let newUsed = allowed ? used + 1 : used
        let d = Decision(allowed: allowed, used: newUsed, limit: limit,
                         remaining: max(limit - newUsed, 0),
                         plan: plan.displayName, offline: true)
        apply(d)
        return d
    }

    // MARK: - Peek (read-only, for "tasks left" UI)

    func refreshQuota() async {
        if SupabaseService.shared.isSignedIn {
            await SupabaseService.shared.ensureFreshToken()
            do {
                let data = try await SupabaseService.shared.authedRequest(
                    path: "/rest/v1/rpc/task_run_quota", method: "POST", body: Data("{}".utf8))
                let r = try JSONDecoder().decode(RPCResult.self, from: data)
                apply(Decision(allowed: (r.remaining ?? 1) != 0,
                               used: r.used ?? 0, limit: r.limit ?? -1,
                               remaining: r.remaining ?? -1,
                               plan: (r.plan ?? "free").capitalized, offline: false))
                return
            } catch { /* fall through to local snapshot */ }
        }
        let plan = EntitlementService.shared.plan
        let used = TaskRunLedger.shared.runsThisMonth
        apply(Decision(allowed: used < plan.monthlyTaskRunQuota,
                       used: used, limit: plan.monthlyTaskRunQuota,
                       remaining: max(plan.monthlyTaskRunQuota - used, 0),
                       plan: plan.displayName, offline: true))
    }

    private func apply(_ d: Decision) {
        used = d.used; limit = d.limit; remaining = d.remaining
        planName = d.plan; lastWasOffline = d.offline
    }
}
