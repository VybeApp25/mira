import Foundation

// MARK: - Task-run ledger (local meter; Supabase quota lands in #3)
//
// The autonomy meter unit is "autonomous task runs / month" (user sees "tasks
// left") — see project_mira_autonomy_direction. This is the ON-DEVICE record of
// those runs: every routed/vision task appends one entry. #3 will sync this to
// the Supabase backend and enforce per-tier monthly quotas + a per-task cost
// ceiling. Until then `canStartRun()` does NOT gate (always allows) — the seam
// exists so the orchestrator already calls it and #3 is a backend swap, not a
// redesign.

@MainActor
final class TaskRunLedger: ObservableObject {
    static let shared = TaskRunLedger()

    struct Entry: Codable, Identifiable {
        var id = UUID()
        let date: Date
        let task: String
        let path: String       // ActuationRouter.Path raw value, or "vision"
        let success: Bool
    }

    @Published private(set) var entries: [Entry]

    private let defaultsKey = "mira_task_run_ledger"
    // Soft local cap purely for the seam; real per-tier quotas arrive in #3.
    // High enough that it never bites before backend enforcement exists.
    private let softMonthlyCap = 100_000

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    /// Runs recorded in the current calendar month.
    var runsThisMonth: Int {
        let cal = Calendar.current
        let now = Date()
        return entries.filter {
            cal.isDate($0.date, equalTo: now, toGranularity: .month)
        }.count
    }

    /// Quota gate. NOT enforced yet (#3 wires real per-tier limits); returns true
    /// unless the soft local cap is somehow hit, so the call site is already in
    /// place. Returns false only to prove the gated path works end to end.
    func canStartRun() -> Bool {
        runsThisMonth < softMonthlyCap
    }

    /// Append one task run and persist.
    func record(task: String, path: String, success: Bool) {
        entries.append(Entry(date: Date(), task: task, path: path, success: success))
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
