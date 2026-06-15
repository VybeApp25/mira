import Foundation
import AppKit
import UserNotifications

// MARK: - Store

@MainActor
final class AgentJobStore: ObservableObject {
    static let shared = AgentJobStore()

    @Published private(set) var jobs: [AgentJob] = []

    // In-memory only. Holds suspended continuations awaiting user approve/deny.
    private var pendingConfirmations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    // In-memory only. Variant selection state for Studio mode.
    private var variantContinuations: [UUID: CheckedContinuation<String, Never>] = [:]
    private var variantPreviewCache: [UUID: [NSImage?]] = [:]

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent_jobs.json")
    }()

    private init() {
        load()
    }

    // MARK: - Submit

    @discardableResult
    func submitJob(prompt: String, apiKey: String, buildMode: WebsiteBuildMode? = nil, referenceImagePaths: [String] = []) -> AgentJob {
        let type = AgentJobType.detect(from: prompt)
        var job = AgentJob(type: type, prompt: prompt)
        job.buildMode = buildMode
        job.referenceImagePaths = referenceImagePaths
        job.steps = Self.buildSteps(for: type, mode: buildMode)
        job.estimatedDuration = buildMode?.estimatedDuration ?? Self.estimatedDuration(for: type)
        jobs.insert(job, at: 0)
        save()
        AudioCueService.shared.playAgentLaunch()
        NotificationCenter.default.post(name: .miraAgentFlightLaunched, object: nil)

        let jobId = job.id
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let store = self else { return }
            await store.markRunning(id: jobId)
            switch type {
            case .websiteBuilder:
                await WebsiteBuilderAgent.run(jobId: jobId, prompt: prompt, apiKey: apiKey, store: store,
                                               buildMode: buildMode ?? .pro, referenceImagePaths: referenceImagePaths)
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

    @discardableResult
    func submitPublishJob(outputEntryId: UUID, target: PublishingAgent.PublishTarget, apiKey: String) -> AgentJob {
        var job = AgentJob(type: .publishWebsite, prompt: "Deploy to \(target.displayName)")
        job.editSourceEntryId = outputEntryId
        job.publishTarget = target.rawValue
        job.steps = Self.buildSteps(for: .publishWebsite)
        job.estimatedDuration = 60
        jobs.insert(job, at: 0)
        save()
        TelemetryService.shared.track(.publishStarted(jobId: job.id, provider: target.rawValue))

        let jobId = job.id
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let store = self else { return }
            await store.markRunning(id: jobId)
            await PublishingAgent.run(
                jobId: jobId,
                outputEntryId: outputEntryId,
                target: target,
                apiKey: apiKey,
                store: store
            )
        }
        return job
    }

    @discardableResult
    func submitEditJob(outputEntryId: UUID, editRequest: String, apiKey: String) -> AgentJob {
        var job = AgentJob(type: .websiteEdit, prompt: editRequest)
        job.editSourceEntryId = outputEntryId
        job.steps = Self.buildSteps(for: .websiteEdit)
        job.estimatedDuration = 75
        jobs.insert(job, at: 0)
        save()

        let jobId = job.id
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let store = self else { return }
            await store.markRunning(id: jobId)
            await WebsiteEditorAgent.run(
                jobId: jobId,
                outputEntryId: outputEntryId,
                editRequest: editRequest,
                apiKey: apiKey,
                store: store
            )
        }
        return job
    }

    @discardableResult
    func submitImprovementJob(outputEntryId: UUID, apiKey: String) -> AgentJob {
        var job = AgentJob(type: .websiteImprovement, prompt: "Improving website quality based on AI audit")
        job.editSourceEntryId = outputEntryId
        job.steps = Self.buildSteps(for: .websiteImprovement)
        job.estimatedDuration = 120
        jobs.insert(job, at: 0)
        save()
        TelemetryService.shared.track(.improvementRequested(jobId: job.id, sourceEntryId: outputEntryId))

        let jobId = job.id
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let store = self else { return }
            await store.markRunning(id: jobId)
            await WebsiteImprovementAgent.run(
                jobId: jobId,
                outputEntryId: outputEntryId,
                apiKey: apiKey,
                store: store
            )
        }
        return job
    }

    @discardableResult
    func submitHealthJob(outputEntryId: UUID, apiKey: String) -> AgentJob {
        var job = AgentJob(type: .websiteHealth, prompt: "Analyzing website health")
        job.editSourceEntryId = outputEntryId
        job.steps = Self.buildSteps(for: .websiteHealth)
        job.estimatedDuration = 45
        jobs.insert(job, at: 0)
        save()

        let jobId = job.id
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let store = self else { return }
            await store.markRunning(id: jobId)
            await WebsiteHealthAgent.run(jobId: jobId, outputEntryId: outputEntryId, apiKey: apiKey, store: store)
        }
        return job
    }

    // MARK: - Queries

    var confirmationPendingJobs: [AgentJob] {
        jobs.filter { $0.status == .waitingForConfirmation }
    }

    var variantSelectionJobs: [AgentJob] {
        jobs.filter { $0.status == .waitingForVariantSelection }
    }

    var blockedJobs: [AgentJob] {
        jobs.filter { $0.status.isBlocked }
    }

    var waitingForInputJobs: [AgentJob] {
        jobs.filter { $0.status == .waitingForInput }
    }

    var activeJobs: [AgentJob] {
        jobs.filter { $0.status.isActive }
    }

    // Legacy — kept for any callers; prefer the granular queries above.
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

    // MARK: - HUD visibility (dismiss from right-side stack without deleting)

    @Published private(set) var hudHidden: Set<UUID> = []

    func hideFromHUD(id: UUID) {
        hudHidden.insert(id)
    }

    func showInHUD(id: UUID) {
        hudHidden.remove(id)
    }

    // MARK: - Cancel

    func cancelJob(id: UUID) {
        if pendingConfirmations[id] != nil {
            denyConfirmation(id: id, reason: "Cancelled by user")
            return
        }
        if variantContinuations[id] != nil {
            variantContinuations[id]?.resume(returning: "")
            variantContinuations.removeValue(forKey: id)
            variantPreviewCache.removeValue(forKey: id)
        }
        update(id) { job in
            job.status = .cancelled
            job.completedAt = Date()
            job.currentStep = "Cancelled"
        }
    }

    // MARK: - Confirmation Gate

    /// Called by an agent before any irreversible action.
    /// Suspends the agent task until the user approves or denies.
    /// Returns true if approved, false if denied.
    func requestConfirmation(id: UUID, request: ConfirmationRequest) async -> Bool {
        update(id) { job in
            job.status = .waitingForConfirmation
            job.confirmationRequest = request
            job.currentStep = "Awaiting approval"
        }
        return await withCheckedContinuation { continuation in
            pendingConfirmations[id] = continuation
        }
    }

    /// User tapped Approve. Resumes the suspended agent.
    func approveConfirmation(id: UUID, reason: String? = nil) {
        update(id) { job in
            job.approvalDecision = ApprovalDecision(approved: true, timestamp: Date(), userReason: reason)
            job.status = .running
            job.currentStep = "Resuming"
        }
        pendingConfirmations[id]?.resume(returning: true)
        pendingConfirmations[id] = nil
    }

    /// User tapped Deny. Resumes the suspended agent with false; agent should return cleanly.
    func denyConfirmation(id: UUID, reason: String? = nil) {
        update(id) { job in
            job.approvalDecision = ApprovalDecision(approved: false, timestamp: Date(), userReason: reason)
            job.status = .cancelled
            job.completedAt = Date()
            job.currentStep = "Cancelled by user"
        }
        pendingConfirmations[id]?.resume(returning: false)
        pendingConfirmations[id] = nil
    }

    // MARK: - Variant Selection Gate (Studio mode)

    /// Called by the agent after generating variants.
    /// Suspends the pipeline until the user selects a variant.
    /// Returns the HTML of the chosen variant, or "" if cancelled.
    func requestVariantSelection(id: UUID, variants: [(name: String, html: String, preview: NSImage?)]) async -> String {
        update(id) { job in
            job.variantOptions = variants.map { VariantOption(name: $0.name, html: $0.html) }
            job.status = .waitingForVariantSelection
            job.currentStep = "Awaiting selection"
        }
        variantPreviewCache[id] = variants.map(\.preview)
        return await withCheckedContinuation { continuation in
            variantContinuations[id] = continuation
        }
    }

    /// UI calls this when the user taps a variant card.
    func selectVariant(id: UUID, variantIndex: Int) {
        guard let continuation = variantContinuations[id],
              let options = jobs.first(where: { $0.id == id })?.variantOptions,
              variantIndex < options.count else {
            variantContinuations[id]?.resume(returning: "")
            variantContinuations.removeValue(forKey: id)
            return
        }
        let html = options[variantIndex].html
        variantContinuations.removeValue(forKey: id)
        variantPreviewCache.removeValue(forKey: id)
        update(id) { job in
            job.status = .running
            job.currentStep = "Resuming"
        }
        continuation.resume(returning: html)
    }

    /// Returns preview images for the variant selection UI.
    func variantPreviews(for id: UUID) -> [NSImage?] {
        variantPreviewCache[id] ?? []
    }

    // MARK: - Example Library

    /// Saves the completed build's HTML as the canonical example for its genre.
    func approveAsExample(jobId: UUID) {
        guard let job = jobs.first(where: { $0.id == jobId }),
              let outputPath = job.result?.outputPath,
              let html = try? String(contentsOfFile: outputPath, encoding: .utf8),
              let genre = job.result?.metadata["genre"] else { return }
        WebsiteBuilderAgent.saveGenreExample(html: html, genre: genre)
    }

    // MARK: - Blocked States

    func markBlockedPermission(id: UUID, reason: String) {
        update(id) { job in
            job.status = .blockedPermission
            job.errorMessage = reason
            job.currentStep = "Permission required"
        }
    }

    func markBlockedTool(id: UUID, reason: String) {
        update(id) { job in
            job.status = .blockedTool
            job.errorMessage = reason
            job.currentStep = "Tool unavailable"
        }
    }

    // MARK: - Granular Progress States

    func markPreparing(id: UUID) {
        update(id) { job in
            job.status = .preparing
            job.currentStep = "Preparing"
        }
    }

    func markReading(id: UUID) {
        update(id) { job in
            job.status = .reading
            job.currentStep = "Reading"
        }
    }

    func markWriting(id: UUID) {
        update(id) { job in
            job.status = .writing
            job.currentStep = "Writing"
        }
    }

    // MARK: - Input Gate (existing waitingForInput flow)

    func markWaitingForInput(id: UUID, readiness: BuildReadiness) {
        update(id) { job in
            job.status = .waitingForInput
            job.buildReadiness = readiness
            job.currentStep = "Waiting for input"
            job.progress = 0.10
        }
    }

    func provideInput(id: UUID, answers: String, apiKey: String) {
        update(id) { job in
            job.status = .running
            job.userProvidedInfo = answers
            job.currentStep = "Resuming with new information"
        }
        guard let job = job(id: id) else { return }
        let prompt = job.prompt
        let mode = job.buildMode
        let refs = job.referenceImagePaths
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let store = self else { return }
            switch job.type {
            case .websiteBuilder:
                await WebsiteBuilderAgent.run(jobId: id, prompt: prompt, apiKey: apiKey, store: store,
                                               buildMode: mode ?? .pro, referenceImagePaths: refs, userProvidedInfo: answers)
            default:
                await GenericAgent.run(jobId: id, prompt: "\(prompt)\n\nAdditional context: \(answers)", apiKey: apiKey, store: store)
            }
        }
    }

    // MARK: - Progress Updates (called by agent runners via await)

    func markRunning(id: UUID) {
        update(id) { job in
            job.status = .running
            job.startedAt = Date()
        }
        if let job = job(id: id) {
            let title = job.result?.metadata["siteName"]
                ?? String(job.prompt.prefix(40))
            CursorCompanionManager.shared.send(
                .agentStarted(title: title, totalSteps: job.steps.count)
            )
            TelemetryService.shared.track(.agentStarted(jobId: job.id, jobType: job.type.rawValue))
            AccessibilityService.shared.announce("\(job.type.rawValue) started")
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
        if let job = job(id: id) {
            let current = (stepIndex ?? 0) + 1
            CursorCompanionManager.shared.send(.agentProgress(
                step:     stepTitle,
                current:  current,
                total:    job.steps.count,
                progress: progress
            ))
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
        if let job = job(id: id) {
            AudioCueService.shared.playAgentComplete()
            postNotification(for: job)
            OutputStore.shared.register(from: job)

            let name    = result.metadata["siteName"] ?? String(job.prompt.prefix(30))
            let title   = "\(name) ready"
            let actions = buildCompletionActions(for: job)
            CursorCompanionManager.shared.send(.agentCompleted(title: title, actions: actions))

            // Telemetry — differentiate by job type
            let duration = job.completedAt?.timeIntervalSince(job.startedAt ?? job.createdAt) ?? 0
            switch job.type {
            case .publishWebsite:
                let provider = job.publishTarget ?? "unknown"
                TelemetryService.shared.track(.publishSucceeded(jobId: job.id, provider: provider))
                let siteName = result.metadata["siteName"] ?? "your website"
                AccessibilityService.shared.announce("Published \(siteName) successfully")
            case .websiteImprovement:
                let delta = result.metadata["deltaAvg"].flatMap(Double.init)
                TelemetryService.shared.track(.improvementApproved(jobId: job.id, scoreDelta: delta))
                let versionName = result.summary
                AccessibilityService.shared.announce(versionName)
            default:
                let name = result.metadata["siteName"] ?? String(job.prompt.prefix(30))
                AccessibilityService.shared.announce("\(job.type.rawValue) complete: \(name)")
            }
            TelemetryService.shared.track(.agentCompleted(
                jobId: job.id, jobType: job.type.rawValue, durationSeconds: duration
            ))
        }
    }

    func failJob(id: UUID, error: String) {
        let source     = job(id: id).map { $0.type.rawValue } ?? "AgentJobStore"
        let resolution = ErrorService.shared.handle(error, source: source, jobId: id)

        update(id) { job in
            job.status        = .failed
            job.errorMessage  = resolution.userMessage
            job.errorCategory = resolution.category
            job.completedAt   = Date()
            job.currentStep   = "Failed"
        }
        AudioCueService.shared.playAgentBlocked()
        CursorCompanionManager.shared.send(.agentFailed(
            message: resolution.userMessage,
            actions: resolution.companionActions
        ))
        AccessibilityService.shared.announce("Task failed: \(resolution.userMessage)")

        if let job = job(id: id) {
            switch job.type {
            case .publishWebsite:
                TelemetryService.shared.track(.publishFailed(
                    jobId: job.id,
                    provider: job.publishTarget ?? "unknown",
                    reason: resolution.userMessage
                ))
            default: break
            }
            TelemetryService.shared.track(.agentFailed(
                jobId: job.id, jobType: job.type.rawValue, reason: resolution.userMessage
            ))
        }
    }

    // MARK: - Private Helpers

    private func buildCompletionActions(for job: AgentJob) -> [CompanionActionSpec] {
        switch job.type {
        case .publishWebsite:
            var actions: [CompanionActionSpec] = []
            if let url = job.result?.metadata["deployedUrl"] ?? job.result?.metadata["publishedUrl"],
               !url.isEmpty {
                actions.append(.openSite())
            }
            actions.append(.viewLibrary())
            return actions
        case .websiteBuilder, .websiteEdit, .websiteImprovement:
            return [.viewLibrary(), .openIsland()]
        default:
            return [.openIsland()]
        }
    }

    private func update(_ id: UUID, mutation: (inout AgentJob) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        let wasTerminal = jobs[idx].status.isTerminal
        mutation(&jobs[idx])
        // When a job first reaches a terminal state, fade its floating chip out
        // after a grace period so the stack doesn't accumulate stale cards.
        if !wasTerminal, jobs[idx].status.isTerminal {
            scheduleHUDAutoDismiss(jobs[idx].id)
        }
        save()
    }

    /// Auto-hide a terminal job's floating chip after a grace period. The job stays
    /// in history; only the chip in the right-side HUD stack is dismissed.
    private func scheduleHUDAutoDismiss(_ id: UUID, after seconds: Double = 12) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.hideFromHUD(id: id)
        }
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

    // MARK: - Static Helpers

    static func buildSteps(for type: AgentJobType, mode: WebsiteBuildMode? = nil) -> [AgentJobStep] {
        switch type {
        case .websiteBuilder:
            let m = mode ?? .pro
            if m == .multiAgent {
                return [
                    AgentJobStep(title: "Researching industry"),
                    AgentJobStep(title: "Building brand strategy"),
                    AgentJobStep(title: "Writing copy"),
                    AgentJobStep(title: "Creative direction"),
                    AgentJobStep(title: "Applying preferences"),
                    AgentJobStep(title: "Enriching brief"),
                    AgentJobStep(title: "Analyzing design references"),
                    AgentJobStep(title: "Creating design direction"),
                    AgentJobStep(title: "Building website"),
                    AgentJobStep(title: "Refining website"),
                    AgentJobStep(title: "Visual critique"),
                    AgentJobStep(title: "Quality audit"),
                    AgentJobStep(title: "Validating"),
                    AgentJobStep(title: "Awaiting approval"),
                    AgentJobStep(title: "Saving project"),
                ]
            }
            var steps: [AgentJobStep] = [
                AgentJobStep(title: "Collecting requirements"),
                AgentJobStep(title: "Enriching brief"),
            ]
            if m.runReferenceAnalysis {
                steps.append(AgentJobStep(title: "Analyzing design references"))
            } else {
                steps.append(AgentJobStep(title: "Loading design references"))
            }
            steps.append(AgentJobStep(title: "Creating design direction"))

            if m == .studio {
                steps += [
                    AgentJobStep(title: "Generating variants"),
                    AgentJobStep(title: "Awaiting selection"),
                ]
            } else {
                steps.append(AgentJobStep(title: "Building website"))
                if m == .pro {
                    steps.append(AgentJobStep(title: "Refining website"))
                }
            }

            if m != .fast {
                steps += [
                    AgentJobStep(title: "Visual critique"),
                    AgentJobStep(title: "Quality audit"),
                ]
            }

            steps += [
                AgentJobStep(title: "Validating"),
                AgentJobStep(title: "Awaiting approval"),
                AgentJobStep(title: "Saving project"),
            ]
            return steps
        case .websiteImprovement:
            return [
                AgentJobStep(title: "Loading website"),
                AgentJobStep(title: "Generating improvements"),
                AgentJobStep(title: "Rendering preview"),
                AgentJobStep(title: "Awaiting approval"),
                AgentJobStep(title: "Saving version"),
            ]
        case .websiteHealth:
            return [
                AgentJobStep(title: "Loading website"),
                AgentJobStep(title: "SEO analysis"),
                AgentJobStep(title: "Accessibility check"),
                AgentJobStep(title: "Mobile & UX check"),
                AgentJobStep(title: "AI recommendations"),
                AgentJobStep(title: "Saving report"),
            ]
        case .websiteEdit:
            return [
                AgentJobStep(title: "Loading website"),
                AgentJobStep(title: "Applying edit"),
                AgentJobStep(title: "Rendering preview"),
                AgentJobStep(title: "Awaiting approval"),
                AgentJobStep(title: "Saving version"),
            ]
        case .publishWebsite:
            return [
                AgentJobStep(title: "Validating website"),
                AgentJobStep(title: "Checking connection"),
                AgentJobStep(title: "Awaiting approval"),
                AgentJobStep(title: "Packaging files"),
                AgentJobStep(title: "Deploying"),
                AgentJobStep(title: "Confirming deployment"),
                AgentJobStep(title: "Saving deployment"),
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
        case .websiteBuilder:    return 180   // default Pro mode; overridden by buildMode.estimatedDuration
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
        jobs = decoded.map { job in
            guard !job.status.isTerminal else { return job }
            var recovered = job
            recovered.completedAt = Date()
            if job.status == .waitingForConfirmation {
                recovered.status = .cancelled
                recovered.errorMessage = "Pending approval was not completed — app was closed."
                recovered.approvalDecision = ApprovalDecision(
                    approved: false, timestamp: Date(), userReason: "App closed"
                )
            } else if job.status == .waitingForVariantSelection {
                recovered.status = .cancelled
                recovered.errorMessage = "Variant selection was not completed — app was closed."
            } else {
                recovered.status = .failed
                recovered.errorMessage = "Job interrupted — app was closed. Tap to retry."
            }
            return recovered
        }
        // Prior-session jobs are all terminal after recovery — start the floating
        // HUD clean instead of resurfacing last session's stale "Done" cards.
        // They remain in history (Agents tab); only the floating chips are hidden.
        hudHidden = Set(jobs.filter { $0.status.isTerminal }.map(\.id))
    }
}
