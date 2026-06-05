// CoordinatorSimulation.swift
// Phase 12.1.5 — Simulation harness (DEBUG only)
//
// Validates coordinator behavior under contention, starvation pressure, and aging.
// Run from any debug entry point: CoordinatorSimulation.shared.runAll()
// Output goes to Xcode console — no UI, no ProjectEngine side effects.

#if DEBUG
import Foundation

@MainActor
final class CoordinatorSimulation {

    static let shared = CoordinatorSimulation()
    private init() {}

    // MARK: - Entry point

    func runAll() {
        phaseA_sequentialAssignment()
        phaseB_contentionLock()
        phaseC_agingAntiStarvation()
        phaseD_preemptionDecisions()
        phaseE_chaosStress()           // 4-agent baseline
        phaseF_capabilityHeatmap()     // demand/supply analysis
        phaseG_expandedRosterRerun()   // 6-agent post-expansion verification
        phaseH_multiProjectLoad()      // multi-project fairness + project lock correctness
    }

    // MARK: - Phase A: sequential assignment — every task gets an agent in resolve() order

    private func phaseA_sequentialAssignment() {
        banner("PHASE A — Sequential Assignment (20 tasks, agents freed after each)")
        let c = AgentCoordinator.makeForTesting()
        let tasks = makeTasks(count: 20)

        let ordered = c.resolve(tasks: tasks)
        c.traceEnabled = true   // show per-agent evaluation for Phase A (educational)
        print("Resolved order (effective priority ↓):")
        for (i, t) in ordered.enumerated() {
            let eff = c.effectivePriority(for: t)
            print("  [\(i+1)] \(t.type.rawValue) priority=\(t.priority) effPriority=\(eff) caps=[\(t.requiredCapabilities.sorted().joined(separator: ","))]")
        }

        print("\nAssignment pass:")
        var byPersona: [AgentPersona: Int] = [:]
        var failed = 0
        for task in ordered {
            if let a = c.assign(task: task) {
                let agent = c.agents.first { $0.id == a.agentId }!
                byPersona[agent.persona, default: 0] += 1
                c.complete(assignment: a)   // free agent immediately
            } else {
                print("  ❌ FAILED: \(task.type.rawValue)[\(task.priority)]")
                failed += 1
            }
        }

        print("\nDistribution:")
        for (persona, count) in byPersona.sorted(by: { $0.value > $1.value }) {
            print("  \(persona.displayName): \(count)")
        }
        starvationCheck(tasks: ordered, byPersona: byPersona)
        print("  Failed: \(failed)/\(ordered.count)")
    }

    // MARK: - Phase B: contention — N tasks lock all N agents simultaneously

    private func phaseB_contentionLock() {
        banner("PHASE B — Contention Lock (full roster locked, overflow blocked)")
        let roster = Agent.builtIn
        let c = AgentCoordinator.makeForTesting(agents: roster)

        // One unique project per agent — locks every slot in the roster
        let projectIds = (0..<roster.count).map { _ in UUID() }
        let taskTypes: [WorkTaskType] = [.implementation, .verification, .research, .review,
                                         .continuation, .verification]
        let tasks: [WorkTask] = zip(projectIds, taskTypes).map { pid, type in
            WorkTask(projectId: pid, type: type, priority: 5)
        }

        var assignments: [AgentAssignment] = []
        for task in tasks {
            if let a = c.assign(task: task) {
                let agent = c.agents.first { $0.id == a.agentId }!
                print("  ✅ \(task.type.rawValue) → \(agent.persona.displayName)")
                assignments.append(a)
            } else {
                print("  ❌ BLOCKED: \(task.type.rawValue)")
            }
        }

        // Attempt one more task — should be blocked (all \(roster.count) agents locked)
        let overflow = WorkTask(projectId: UUID(), type: .implementation, priority: 10)
        print("\n  Overflow task (all \(roster.count) agents busy):")
        if c.assign(task: overflow) == nil {
            print("  ✅ Correctly blocked — all agents assigned")
        } else {
            print("  ❌ ERROR — assigned despite full lock")
        }

        // Release one agent, retry
        if let first = assignments.first {
            c.complete(assignment: first)
            print("\n  After releasing first agent:")
            if let retry = c.assign(task: overflow) {
                let agent = c.agents.first { $0.id == retry.agentId }!
                print("  ✅ Assigned to \(agent.persona.displayName)")
            }
        }
    }

    // MARK: - Phase C: aging — old low-priority tasks eventually outrank newer ones

    private func phaseC_agingAntiStarvation() {
        banner("PHASE C — Aging Anti-Starvation")
        let c = AgentCoordinator.makeForTesting()

        let now = Date()
        let tasks: [WorkTask] = [
            WorkTask(projectId: UUID(), type: .implementation, priority: 8,
                     createdAt: now),                                    // new, high priority
            WorkTask(projectId: UUID(), type: .research, priority: 1,
                     createdAt: now.addingTimeInterval(-25 * 60)),       // 25 min old, low priority
            WorkTask(projectId: UUID(), type: .verification, priority: 3,
                     createdAt: now.addingTimeInterval(-10 * 60)),       // 10 min old, medium
            WorkTask(projectId: UUID(), type: .review, priority: 0,
                     createdAt: now.addingTimeInterval(-60 * 60)),       // 1 hour old, zero priority
        ]

        print("Task effective priorities (aging applied):")
        for t in tasks {
            let eff = c.effectivePriority(for: t)
            let age = Int(now.timeIntervalSince(t.createdAt) / 60)
            print("  \(t.type.rawValue) base=\(t.priority) age=\(age)m effPriority=\(eff)")
        }

        print("\nResolved order:")
        let ordered = c.resolve(tasks: tasks)
        for (i, t) in ordered.enumerated() {
            print("  [\(i+1)] \(t.type.rawValue) effPriority=\(c.effectivePriority(for: t))")
        }

        let top = ordered.first
        if top?.type == .review || top?.type == .research {
            print("\n  ✅ Old low-priority task correctly elevated by aging")
        } else {
            print("\n  ℹ️  Newest high-priority task still leads (expected if aging boost < delta)")
        }
    }

    // MARK: - Phase D: preemption decisions

    private func phaseD_preemptionDecisions() {
        banner("PHASE D — Preemption Decisions")
        let c = AgentCoordinator.makeForTesting()
        let now = Date()

        let scenarios: [(incoming: WorkTask, current: WorkTask, label: String)] = [
            // Clear preemption: +5 delta
            (
                WorkTask(projectId: UUID(), type: .implementation, priority: 7),
                WorkTask(projectId: UUID(), type: .research,       priority: 2),
                "Clear priority preemption"
            ),
            // Below threshold: +2 delta
            (
                WorkTask(projectId: UUID(), type: .verification, priority: 4),
                WorkTask(projectId: UUID(), type: .review,       priority: 2),
                "Below threshold (no preempt)"
            ),
            // Age-assisted: low base delta + old task
            (
                WorkTask(projectId: UUID(), type: .continuation, priority: 3,
                         createdAt: now.addingTimeInterval(-20 * 60)),   // 20 min old
                WorkTask(projectId: UUID(), type: .implementation, priority: 2),
                "Age-assisted preemption (+4 aging)"
            ),
            // Equal priority, no age advantage
            (
                WorkTask(projectId: UUID(), type: .implementation, priority: 5),
                WorkTask(projectId: UUID(), type: .verification,   priority: 5),
                "Equal priority (no preempt)"
            ),
        ]

        for s in scenarios {
            let d = c.canPreempt(incoming: s.incoming, current: s.current)
            let mark = d.allowed ? "✅ PREEMPT" : "🚫 QUEUE"
            print("  \(mark) \"\(s.label)\"")
            print("         reason: \(d.reason) (score=\(d.score))")
        }
    }

    // MARK: - Helpers

    private func makeTasks(count: Int) -> [WorkTask] {
        let types = WorkTaskType.allCases
        let capPools: [Set<String>] = [
            [],
            ["implementation"],
            ["verification"],
            ["research"],
            ["debugging"],
            ["research", "review"],
            ["verification", "testing"],
            ["documentation"],
        ]
        let now = Date()
        return (0..<count).map { i in
            let type     = types[i % types.count]
            let priority = (i * 3 + 7) % 10
            let caps     = capPools[i % capPools.count]
            let age      = TimeInterval((i * 4) % 60) * 60   // 0–56 min old, in 4-min steps
            return WorkTask(
                projectId:            UUID(),
                type:                 type,
                priority:             priority,
                requiredCapabilities: caps,
                createdAt:            now.addingTimeInterval(-age)
            )
        }
    }

    private func starvationCheck(tasks: [WorkTask], byPersona: [AgentPersona: Int]) {
        let typesInTasks = Set(tasks.map { $0.type })
        let unassignedTypes = typesInTasks.filter { type in
            let preferred: AgentPersona
            switch type {
            case .implementation, .continuation: preferred = .developer
            case .verification:                  preferred = .tester
            case .research, .review:             preferred = .researcher
            }
            return byPersona[preferred] == nil || byPersona[preferred] == 0
        }
        if unassignedTypes.isEmpty {
            print("  ✅ No starvation — all task types received assignments")
        } else {
            print("  ⚠️  Potential starvation: \(unassignedTypes.map(\.rawValue).sorted().joined(separator: ", "))")
        }
    }

    // MARK: - Phase E: chaos stress — adversarial scheduler test

    private func phaseE_chaosStress(seed: UInt64 = 42, taskCount: Int = 50, cycles: Int = 10) {
        runChaosStress(
            label: "PHASE E — Chaos Stress (4-agent baseline, \(taskCount) tasks, \(cycles) cycles, seed=\(seed))",
            seed: seed, taskCount: taskCount, cycles: cycles,
            agents: Array(Agent.builtIn.prefix(4))
        )
    }

    private func runChaosStress(label: String, seed: UInt64, taskCount: Int, cycles: Int, agents: [Agent]) {
        banner(label)
        let c = AgentCoordinator.makeForTesting(agents: agents)
        c.traceEnabled = false
        var rng = SeededRNG(seed: seed)
        let now = Date()

        let capPools: [Set<String>] = [
            [],
            ["implementation"],
            ["verification"],
            ["research"],
            ["debugging"],
            ["documentation"],
            ["implementation", "debugging"],
            ["research", "review"],
        ]
        let types = WorkTaskType.allCases

        // Generate tasks — randomized age, priority, caps
        var taskMap: [UUID: WorkTask] = [:]
        var pendingIds   = Set<UUID>()
        var completedIds = Set<UUID>()
        var neverAssigned = Set<UUID>()

        for _ in 0..<taskCount {
            let type     = types[Int(rng.next() % UInt64(types.count))]
            let priority = Int(rng.next() % 11)
            let ageSec   = TimeInterval(rng.next() % 7200)   // 0–2 hours
            let caps     = capPools[Int(rng.next() % UInt64(capPools.count))]
            let task = WorkTask(
                projectId:            UUID(),
                type:                 type,
                priority:             priority,
                requiredCapabilities: caps,
                createdAt:            now.addingTimeInterval(-ageSec)
            )
            taskMap[task.id]   = task
            pendingIds.insert(task.id)
            neverAssigned.insert(task.id)
        }

        var totalAssigned = 0
        var totalBlocked  = 0
        var preemptFlips  = 0
        var lastPreempt: [String: Bool] = [:]

        for cycle in 1...cycles {
            // Resolve pending
            let pending = pendingIds.compactMap { taskMap[$0] }
            let ordered = c.resolve(tasks: pending)

            var cycleAssigned = 0
            var cycleBlocked  = 0

            for task in ordered {
                if let a = c.assign(task: task) {
                    pendingIds.remove(task.id)
                    neverAssigned.remove(task.id)
                    cycleAssigned += 1
                    totalAssigned += 1
                } else {
                    cycleBlocked += 1
                    totalBlocked += 1
                }
            }

            // Randomly complete ~40% of active assignments
            for a in c.activeAssignments where rng.next() % 100 < 40 {
                c.complete(assignment: a)
                completedIds.insert(a.taskId)
            }

            // Preemption oscillation probe: top pending vs top active
            if let incoming = ordered.first,
               let active   = c.activeAssignments.first,
               let current  = taskMap[active.taskId] {
                let key = "\(incoming.id.uuidString.prefix(6))-\(current.id.uuidString.prefix(6))"
                let d = c.canPreempt(incoming: incoming, current: current)
                if let prev = lastPreempt[key], prev != d.allowed { preemptFlips += 1 }
                lastPreempt[key] = d.allowed
            }

            let line = "  Cycle \(String(format: "%2d", cycle)): +assigned=\(cycleAssigned) blocked=\(cycleBlocked) active=\(c.activeAssignments.count) pending=\(pendingIds.count) done=\(completedIds.count)"
            print(line)
            fflush(stdout)
        }

        // ── Results ──────────────────────────────────────────────────────────────
        func fp(_ s: String) { print(s); fflush(stdout) }

        fp("\nResults after \(cycles) cycles:")
        fp("  Total assigned:   \(totalAssigned)")
        fp("  Total blocked:    \(totalBlocked)")
        fp("  Completed:        \(completedIds.count)/\(taskCount)")
        fp("  Still pending:    \(pendingIds.count)/\(taskCount)")
        fp("  Never assigned:   \(neverAssigned.count)/\(taskCount)")
        fp("  Preemption flips: \(preemptFlips)")

        // Starvation breakdown
        let starved = neverAssigned.compactMap { taskMap[$0] }
        if starved.isEmpty {
            fp("  ✅ No starvation — every task assigned at least once")
        } else {
            let byType = Dictionary(grouping: starved, by: { $0.type })
            fp("  ⚠️  Starved tasks by type:")
            for (type, ts) in byType.sorted(by: { $0.value.count > $1.value.count }) {
                let avgAge = ts.map { now.timeIntervalSince($0.createdAt) / 60.0 }.reduce(0, +) / Double(ts.count)
                let avgPri = ts.map { $0.priority }.reduce(0, +) / ts.count
                fp("    \(type.rawValue): \(ts.count) (avgPriority=\(avgPri) avgAge=\(Int(avgAge))m)")
            }
        }

        // Oscillation verdict
        if preemptFlips > 10 {
            fp("  ⚠️  Oscillation risk — \(preemptFlips) preemption flips detected")
        } else {
            fp("  ✅ Preemption stable (\(preemptFlips) flips)")
        }

        fp("\n  Agent roster: \(c.agents.count) agents — \(c.agents.map { $0.persona.displayName }.joined(separator: ", "))")
    }

    // MARK: - Phase F: capability heatmap — demand/supply analysis

    private func phaseF_capabilityHeatmap() {
        banner("PHASE F — Capability Heatmap (4-agent baseline, seed=42)")

        var rng = SeededRNG(seed: 42)
        let now = Date()
        let roster = Array(Agent.builtIn.prefix(4))

        // Generate same 50-task chaos workload as Phase E
        let capPools: [Set<String>] = [
            [],
            ["implementation"],
            ["verification"],
            ["research"],
            ["debugging"],
            ["documentation"],
            ["implementation", "debugging"],
            ["research", "review"],
        ]
        let types = WorkTaskType.allCases
        var tasks: [WorkTask] = []
        for _ in 0..<50 {
            let type  = types[Int(rng.next() % UInt64(types.count))]
            let prio  = Int(rng.next() % 11)
            let age   = TimeInterval(rng.next() % 7200)
            let caps  = capPools[Int(rng.next() % UInt64(capPools.count))]
            tasks.append(WorkTask(projectId: UUID(), type: type, priority: prio,
                                  requiredCapabilities: caps,
                                  createdAt: now.addingTimeInterval(-age)))
        }

        // Compute demand per capability (only tasks with non-empty cap sets)
        var capDemand: [String: Int] = [:]
        var wildcardCount = 0
        var uncoverable = 0
        for task in tasks {
            if task.requiredCapabilities.isEmpty { wildcardCount += 1; continue }
            if !roster.contains(where: { $0.capabilityTags.isSuperset(of: task.requiredCapabilities) }) {
                uncoverable += 1
            }
            task.requiredCapabilities.forEach { capDemand[$0, default: 0] += 1 }
        }

        // Compute supply per capability (agents that have it)
        var capSupply: [String: Int] = [:]
        for agent in roster {
            agent.capabilityTags.forEach { capSupply[$0, default: 0] += 1 }
        }

        // Sort demanded caps by D/S ratio descending (highest risk first)
        let sorted = capDemand.keys.sorted { a, b in
            let dA = capDemand[a]!, sA = capSupply[a] ?? 0
            let dB = capDemand[b]!, sB = capSupply[b] ?? 0
            let ratioA = sA == 0 ? Double.infinity : Double(dA) / Double(sA)
            let ratioB = sB == 0 ? Double.infinity : Double(dB) / Double(sB)
            return ratioA > ratioB
        }

        print("\nCapability          | Demand | Supply | D/S   | Risk")
        print("────────────────────┼────────┼────────┼───────┼──────")
        var bottlenecks: [String] = []
        for cap in sorted {
            let d = capDemand[cap]!
            let s = capSupply[cap] ?? 0
            let ratio = s == 0 ? Double.infinity : Double(d) / Double(s)
            let ratioStr = s == 0 ? "∞    " : String(format: "%.2f ", ratio)
            let risk = ratio > 4 ? "🔴 HIGH" : ratio > 2 ? "🟡 MED " : "🟢 LOW "
            if ratio > 3 { bottlenecks.append(cap) }
            let pc = cap.padding(toLength: 20, withPad: " ", startingAt: 0)
            let pd = String(d).padding(toLength: 7, withPad: " ", startingAt: 0)
            let ps = String(s).padding(toLength: 7, withPad: " ", startingAt: 0)
            let pr = ratioStr.padding(toLength: 6, withPad: " ", startingAt: 0)
            print("  \(pc)| \(pd)| \(ps)| \(pr)| \(risk)")
        }
        print("\n  Wildcard tasks (any agent): \(wildcardCount)")
        if uncoverable > 0 {
            print("  ⚠️  Uncoverable by any agent: \(uncoverable)")
        }
        if bottlenecks.isEmpty {
            print("\n  ✅ No severe bottlenecks (D/S ≤ 3 for all capabilities)")
        } else {
            print("\n  🔴 Bottlenecks (D/S > 3): \(bottlenecks.sorted().joined(separator: ", "))")
            // Which personas serve these bottlenecked capabilities?
            let needed = Set(bottlenecks.compactMap { cap in
                roster.first { $0.capabilityTags.contains(cap) }?.persona.displayName
            })
            if !needed.isEmpty {
                print("  → Expand roster: \(needed.sorted().joined(separator: ", "))")
            }
        }
        fflush(stdout)
    }

    // MARK: - Phase G: expanded roster re-run — verify Option A impact

    private func phaseG_expandedRosterRerun() {
        runChaosStress(
            label: "PHASE G — Expanded Roster Re-run (6-agent, 50 tasks, 10 cycles, seed=42)",
            seed: 42, taskCount: 50, cycles: 10,
            agents: Agent.builtIn   // full 6-agent roster after Option A
        )
    }

    // MARK: - Phase H: multi-project load — fairness + project lock correctness

    private func phaseH_multiProjectLoad() {
        banner("PHASE H — Multi-Project Load (4 projects, 100 tasks, 20 cycles, seed=42)")

        // 4 named projects with defined task mixes
        let projectIds   = (0..<4).map { _ in UUID() }
        let projectNames = ["Vybe", "Mira", "LOCKED", "AI Esports"]
        // (intent, count, priority)
        let mixes: [[(WorkIntent, Int, Int)]] = [
            [(.implementation, 15, 6), (.verification, 5, 7)],   // Vybe: 20 tasks
            [(.research, 10, 5),       (.review, 5, 5)],          // Mira: 15 tasks
            [(.implementation, 8, 2),  (.continuation, 4, 2)],    // LOCKED: 12 tasks (low priority)
            [(.research, 6, 6),        (.implementation, 6, 6)],   // AI Esports: 12 tasks
        ]

        // Build stable task store: UUID → (WorkTask, projectName)
        var taskStore:   [UUID: WorkTask] = [:]
        var taskProject: [UUID: String]   = [:]
        var pendingIds = Set<UUID>()
        let now = Date()

        for (pi, pid) in projectIds.enumerated() {
            var age = 0
            for (intent, count, priority) in mixes[pi] {
                for _ in 0..<count {
                    let t = WorkTask(projectId: pid,
                                     type:      workTaskType(for: intent),
                                     priority:  priority,
                                     intent:    intent,
                                     createdAt: now.addingTimeInterval(-TimeInterval(age * 120)))
                    taskStore[t.id]   = t
                    taskProject[t.id] = projectNames[pi]
                    pendingIds.insert(t.id)
                    age += 1
                }
            }
        }

        let c = AgentCoordinator.makeForTesting(agents: Agent.builtIn)
        c.traceEnabled = false
        var rng = SeededRNG(seed: 42)

        var assignedByProject:  [String: Int]      = [:]
        var completedByProject: [String: Int]       = [:]
        var firstCycle:         [String: Int]       = [:]
        var assignedByIntent:   [WorkIntent: Int]   = [:]
        var lockViolations = 0
        var completedIds   = Set<UUID>()
        var neverAssigned  = Set<UUID>(taskStore.keys)

        for cycle in 1...20 {
            let pending = pendingIds.compactMap { taskStore[$0] }
            let ordered = c.resolve(tasks: pending)

            var cycleAssigned = 0
            for task in ordered {
                let preCheck = c.activeAssignments.contains { $0.projectId == task.projectId }
                if let a = c.assign(task: task) {
                    if preCheck { lockViolations += 1 }
                    let pname = taskProject[task.id] ?? "?"
                    pendingIds.remove(task.id)
                    neverAssigned.remove(task.id)
                    assignedByProject[pname, default: 0]  += 1
                    assignedByIntent[task.intent, default: 0] += 1
                    if firstCycle[pname] == nil { firstCycle[pname] = cycle }
                    cycleAssigned += 1
                }
            }

            for a in c.activeAssignments where rng.next() % 100 < 40 {
                c.complete(assignment: a)
                completedIds.insert(a.taskId)
                if let pname = taskProject[a.taskId] {
                    completedByProject[pname, default: 0] += 1
                }
            }

            print("  Cycle \(String(format: "%2d", cycle)): +assigned=\(cycleAssigned) active=\(c.activeAssignments.count) pending=\(pendingIds.count) done=\(completedIds.count)")
            fflush(stdout)
        }

        // ── Results ─────────────────────────────────────────────────────────
        func fp(_ s: String) { print(s); fflush(stdout) }

        let totalByProject = zip(projectNames, mixes).map { name, mix in
            (name, mix.reduce(0) { $0 + $1.1 })
        }
        fp("\nPer-project results:")
        fp("  Project       | Total | Assigned | Completed | 1st Cycle | Starved")
        fp("  ──────────────┼───────┼──────────┼───────────┼───────────┼───────")
        for (name, total) in totalByProject {
            let asgn    = assignedByProject[name] ?? 0
            let done    = completedByProject[name] ?? 0
            let fc      = firstCycle[name].map { String($0) } ?? "never"
            let starved = neverAssigned.filter { taskProject[$0] == name }.count
            fp("  \(name.padding(toLength: 14, withPad: " ", startingAt: 0))| \(String(total).padding(toLength: 6, withPad: " ", startingAt: 0))| \(String(asgn).padding(toLength: 9, withPad: " ", startingAt: 0))| \(String(done).padding(toLength: 10, withPad: " ", startingAt: 0))| \(fc.padding(toLength: 10, withPad: " ", startingAt: 0))| \(starved)")
        }

        fp("\nIntent distribution (assignments):")
        for intent in [WorkIntent.implementation, .verification, .research, .review, .continuation] {
            let n = assignedByIntent[intent] ?? 0
            fp("  \(intent.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)): \(n)")
        }

        fp("\nProject lock violations: \(lockViolations == 0 ? "✅ 0 (invariant holds)" : "❌ \(lockViolations)")")

        let counts = projectNames.map { assignedByProject[$0] ?? 0 }
        let maxA = counts.max() ?? 0, minA = counts.min() ?? 0
        if maxA > max(minA * 3, 3) {
            fp("⚠️  Project skew: max=\(maxA) vs min=\(minA) — priority difference may be biasing larger projects")
        } else {
            fp("✅ Cross-project distribution balanced: max=\(maxA) vs min=\(minA)")
        }
    }

    private func workTaskType(for intent: WorkIntent) -> WorkTaskType {
        switch intent {
        case .implementation: return .implementation
        case .verification:   return .verification
        case .research:       return .research
        case .review:         return .review
        case .continuation:   return .continuation
        }
    }

    // MARK: - SeededRNG (reproducible chaos)

    private struct SeededRNG {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func banner(_ title: String) {
        print("\n" + String(repeating: "═", count: 56))
        print("  \(title)")
        print(String(repeating: "═", count: 56))
    }
}
#endif
