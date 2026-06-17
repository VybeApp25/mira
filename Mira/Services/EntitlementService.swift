import Foundation
import Combine

// MARK: - Plan

enum SubscriptionPlan: String, Codable, Equatable {
    case free
    case pro
    case ultra

    var displayName: String {
        switch self {
        case .free:  return "Free"
        case .pro:   return "Pro"
        case .ultra: return "Ultra"
        }
    }

    var maxConcurrentAgents: Int {
        switch self {
        case .free:  return 0
        case .pro:   return 2
        case .ultra: return 5
        }
    }

    /// Monthly autonomous-task-run quota (the autonomy meter unit). Mirrors the
    /// server-side `monthly_task_quota()` SQL — the SERVER is authoritative; this
    /// is only for the offline fallback and "tasks left" display. -1 = uncapped.
    /// See project_mira_autonomy_direction.
    var monthlyTaskRunQuota: Int {
        switch self {
        case .free:  return 5
        case .pro:   return 100
        case .ultra: return 500
        }
    }
}

// MARK: - Entitlements

enum Entitlement {
    case runAgents
    case buildWebsites
    case buildApps
    case useVoiceMode
    case useScreenGuidance
    case deepResearch
    case contentGeneration
    case unlimitedChat

    var requiredPlan: SubscriptionPlan { .pro }
}

// MARK: - Service

final class EntitlementService: ObservableObject {
    static let shared = EntitlementService()

    @Published private(set) var plan: SubscriptionPlan = .free

    private let planKey = "mira_subscription_plan"
    private let legacyProKey = "mira_is_pro"

    private init() {
        if let raw = UserDefaults.standard.string(forKey: planKey),
           let saved = SubscriptionPlan(rawValue: raw) {
            plan = saved
        } else if UserDefaults.standard.bool(forKey: legacyProKey) {
            // Migrate old isPro flag
            plan = .pro
            persist()
        }
    }

    func can(_ entitlement: Entitlement) -> Bool {
        switch entitlement {
        case .useVoiceMode:
            return true
        case .runAgents, .buildWebsites, .useScreenGuidance, .deepResearch, .contentGeneration, .unlimitedChat:
            return plan == .pro || plan == .ultra
        case .buildApps:
            return plan == .ultra
        }
    }

    var maxConcurrentAgents: Int { plan.maxConcurrentAgents }

    // Called when the backend confirms a subscription change
    func updatePlan(_ newPlan: SubscriptionPlan) {
        plan = newPlan
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(plan.rawValue, forKey: planKey)
        // Keep legacy key in sync so old isPro checks still work
        UserDefaults.standard.set(plan != .free, forKey: legacyProKey)
    }
}
