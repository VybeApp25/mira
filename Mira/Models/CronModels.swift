import Foundation

// MARK: - Schedule

enum CronSchedule: Codable, Equatable {
    case hourly
    case daily(hour: Int, minute: Int)
    case weekly(weekday: Int, hour: Int, minute: Int) // weekday: 1=Sun…7=Sat
    case custom(intervalMinutes: Int)

    var displayName: String {
        switch self {
        case .hourly:             return "Hourly"
        case .daily(let h, let m):return "Daily at \(String(format: "%02d:%02d", h, m))"
        case .weekly(let d, let h, let m):
            let days = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
            let day = d >= 1 && d <= 7 ? days[d-1] : "?"
            return "Every \(day) at \(String(format: "%02d:%02d", h, m))"
        case .custom(let mins): return "Every \(mins)m"
        }
    }

    var intervalSeconds: TimeInterval {
        switch self {
        case .hourly:             return 3600
        case .daily:              return 86400
        case .weekly:             return 604800
        case .custom(let m):      return TimeInterval(m * 60)
        }
    }

    func nextFire(after date: Date = Date()) -> Date {
        let cal = Calendar.current
        switch self {
        case .hourly:
            return date.addingTimeInterval(3600)
        case .daily(let h, let m):
            var comps = cal.dateComponents([.year, .month, .day], from: date)
            comps.hour = h; comps.minute = m; comps.second = 0
            let today = cal.date(from: comps)!
            return today > date ? today : cal.date(byAdding: .day, value: 1, to: today)!
        case .weekly(let wd, let h, let m):
            var comps = cal.dateComponents([.year, .month, .day, .weekday], from: date)
            comps.hour = h; comps.minute = m; comps.second = 0
            let current = comps.weekday ?? 1
            let daysAhead = ((wd - current) + 7) % 7
            let base = cal.date(byAdding: .day, value: daysAhead, to: date)!
            var target = cal.dateComponents([.year, .month, .day], from: base)
            target.hour = h; target.minute = m; target.second = 0
            let fire = cal.date(from: target)!
            return fire > date ? fire : cal.date(byAdding: .weekOfYear, value: 1, to: fire)!
        case .custom(let mins):
            return date.addingTimeInterval(TimeInterval(mins * 60))
        }
    }
}

// MARK: - Cron Job

struct MiraCron: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var prompt: String
    var schedule: CronSchedule
    var enabled: Bool
    var lastRunAt: Date?
    var lastRunResult: String?
    var nextFireAt: Date

    init(name: String, prompt: String, schedule: CronSchedule) {
        self.id           = UUID()
        self.name         = name
        self.prompt       = prompt
        self.schedule     = schedule
        self.enabled      = true
        self.nextFireAt   = schedule.nextFire()
    }
}

// MARK: - Store

@MainActor
final class CronStore: ObservableObject {
    static let shared = CronStore()

    @Published private(set) var crons: [MiraCron] = []

    private let storeKey = "mira_crons"

    private init() { load() }

    // MARK: - CRUD

    func add(_ cron: MiraCron) {
        crons.append(cron)
        save()
    }

    func update(_ cron: MiraCron) {
        guard let idx = crons.firstIndex(where: { $0.id == cron.id }) else { return }
        crons[idx] = cron
        save()
    }

    func delete(id: UUID) {
        crons.removeAll { $0.id == id }
        save()
    }

    func toggle(id: UUID) {
        guard let idx = crons.firstIndex(where: { $0.id == id }) else { return }
        crons[idx].enabled.toggle()
        save()
    }

    func recordRun(id: UUID, result: String) {
        guard let idx = crons.firstIndex(where: { $0.id == id }) else { return }
        crons[idx].lastRunAt     = Date()
        crons[idx].lastRunResult = result
        crons[idx].nextFireAt    = crons[idx].schedule.nextFire()
        save()
    }

    // MARK: - Due crons

    var dueCrons: [MiraCron] {
        crons.filter { $0.enabled && $0.nextFireAt <= Date() }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(crons) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let stored = try? JSONDecoder().decode([MiraCron].self, from: data) else { return }
        crons = stored
    }
}
