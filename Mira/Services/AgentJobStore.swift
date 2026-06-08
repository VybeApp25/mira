import Foundation
import UserNotifications

// MARK: - Store

@MainActor
final class AgentJobStore: ObservableObject {
    static let shared = AgentJobStore()

    @Published private(set) var jobs: [AgentJob] = []

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent_jobs.json")
    }()

    private init() {
        load()
    }

    // MARK: - Submit (creates job and starts background execution)

    @discardableResult
    func submitJob(prompt: String, apiKey: String) -> AgentJob {
        let type = AgentJobType.detect(from: prompt)
        var job = AgentJob(type: type, prompt: prompt)
        job.steps = Self.buildSteps(for: type)
        job.estimatedDuration = Self.estimatedDuration(for: type)
        jobs.insert(job, at: 0)
        save()

        let jobId = job.id
        // Task.detached so the agent work runs on the cooperative thread pool,
        // not pinned to the main actor. Each await store.updateStep(...) will
        // hop to the main actor briefly, then return to the pool for the next call.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let store = self else { return }
            await store.markRunning(id: jobId)
            switch type {
            case .websiteBuilder:
                await WebsiteBuilderAgent.run(jobId: jobId, prompt: prompt, apiKey: apiKey, store: store)
            case .deepResearch:
                await ResearchAgent.run(jobId: jobId, prompt: prompt, apiKey: apiKey, store: store)
            case .contentGeneration:
                await ContentAgent.run(jobId: jobId, prompt: prompt, apiKey: apiKey, store: store)
            default:
                await GenericAgent.run(jobId: jobId, prompt: prompt, apiKey: apiKey, store: store)
            }
        }

        return job
    }

    // MARK: - Queries

    var runningJobs: [AgentJob] {
        jobs.filter { $0.status == .running || $0.status == .queued || $0.status == .waitingForInput }
    }

    var completedJobs: [AgentJob] {
        jobs.filter { $0.status.isTerminal }
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }

    func job(id: UUID) -> AgentJob? {
        jobs.first { $0.id == id }
    }

    func cancelJob(id: UUID) {
        update(id) { job in
            job.status = .cancelled
            job.completedAt = Date()
            job.currentStep = "Cancelled"
        }
    }

    // MARK: - Progress updates (called by agent runners via await — hops to main actor)

    func markRunning(id: UUID) {
        update(id) { job in
            job.status = .running
            job.startedAt = Date()
        }
    }

    func updateStep(id: UUID, stepTitle: String, progress: Double, stepIndex: Int? = nil) {
        update(id) { job in
            job.currentStep = stepTitle
            job.progress = min(max(progress, 0), 1)
            guard let idx = stepIndex, idx < job.steps.count else { return }
            job.steps[idx].status = .running
            if job.steps[idx].startedAt == nil { job.steps[idx].startedAt = Date() }
            for i in 0 ..< idx where job.steps[i].status != .completed {
                job.steps[i].status = .completed
                job.steps[i].completedAt = Date()
            }
        }
    }

    func appendLog(id: UUID, stepIndex: Int, message: String) {
        update(id) { job in
            guard stepIndex < job.steps.count else { return }
            let existing = job.steps[stepIndex].log ?? ""
            job.steps[stepIndex].log = existing.isEmpty ? message : "\(existing)\n\(message)"
        }
    }

    func completeJob(id: UUID, result: AgentJobResult) {
        update(id) { job in
            job.status = .completed
            job.progress = 1.0
            job.result = result
            job.completedAt = Date()
            job.currentStep = "Completed"
            for i in 0 ..< job.steps.count {
                job.steps[i].status = .completed
                if job.steps[i].completedAt == nil { job.steps[i].completedAt = Date() }
            }
        }
        if let job = job(id: id) { postNotification(for: job) }
    }

    func failJob(id: UUID, error: String) {
        update(id) { job in
            job.status = .failed
            job.errorMessage = error
            job.completedAt = Date()
            job.currentStep = "Failed"
        }
    }

    // MARK: - Private helpers

    private func update(_ id: UUID, mutation: (inout AgentJob) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutation(&jobs[idx])
        save()
    }

    private func postNotification(for job: AgentJob) {
        let content = UNMutableNotificationContent()
        content.title = "\(job.type.rawValue) Complete"
        content.body = job.result?.summary ?? "Your task is ready."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        )
    }

    // MARK: - Static helpers (nonisolated-safe: no instance state)

    static func buildSteps(for type: AgentJobType) -> [AgentJobStep] {
        switch type {
        case .websiteBuilder:
            return [
                AgentJobStep(title: "Analyzing requirements"),
                AgentJobStep(title: "Generating structure"),
                AgentJobStep(title: "Creating design"),
                AgentJobStep(title: "Writing code"),
                AgentJobStep(title: "Validating output"),
                AgentJobStep(title: "Preparing preview"),
                AgentJobStep(title: "Saving project"),
            ]
        case .deepResearch:
            return [
                AgentJobStep(title: "Defining research scope"),
                AgentJobStep(title: "Gathering information"),
                AgentJobStep(title: "Analyzing findings"),
                AgentJobStep(title: "Synthesizing insights"),
                AgentJobStep(title: "Writing report"),
                AgentJobStep(title: "Saving report"),
            ]
        case .contentGeneration:
            return [
                AgentJobStep(title: "Understanding brief"),
                AgentJobStep(title: "Generating outline"),
                AgentJobStep(title: "Writing content"),
                AgentJobStep(title: "Refining draft"),
                AgentJobStep(title: "Saving file"),
            ]
        default:
            return [
                AgentJobStep(title: "Processing request"),
                AgentJobStep(title: "Generating result"),
                AgentJobStep(title: "Saving output"),
            ]
        }
    }

    static func estimatedDuration(for type: AgentJobType) -> TimeInterval {
        switch type {
        case .websiteBuilder:    return 45
        case .deepResearch:      return 90
        case .contentGeneration: return 30
        case .appBuilder:        return 120
        default:                 return 30
        }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AgentJob].self, from: data) else { return }
        // Recover interrupted jobs — mark them failed so user can retry
        jobs = decoded.map { job in
            guard !job.status.isTerminal else { return job }
            var recovered = job
            recovered.status = .failed
            recovered.errorMessage = "Job interrupted — app was closed. Tap to retry."
            recovered.completedAt = Date()
            return recovered
        }
    }
}
