import SwiftUI
import AppKit

private let surface  = Color(red: 0.11, green: 0.11, blue: 0.13)
private let surface2 = Color(red: 0.14, green: 0.14, blue: 0.17)
private let accent   = DS.Colors.accent
private let green    = Color(red: 0.20, green: 0.84, blue: 0.29)
private let amber    = Color(red: 1.0,  green: 0.78, blue: 0.20)
private let orange   = Color(red: 1.0,  green: 0.60, blue: 0.20)
private let red      = Color(red: 1.0,  green: 0.35, blue: 0.35)

// MARK: - Main Tab

struct AgentsTabView: View {
    @ObservedObject var taskStore: AgentTaskStore  // legacy Composio tasks (kept for compatibility)
    @ObservedObject var miraState: MiraState
    @ObservedObject var overlay: OverlayWindowController
    let capture: ScreenCaptureService
    @ObservedObject var voice: VoiceService

    @StateObject private var jobStore = AgentJobStore.shared
    @StateObject private var entitlements = EntitlementService.shared
    @State private var input = ""
    @State private var detailJob: AgentJob? = nil
    @State private var answeringJob: AgentJob? = nil
    @State private var detectedType: AgentJobType = .custom
    @State private var websiteMode: WebsiteBuildMode = .pro
    @State private var referenceImagePaths: [String] = []
    @State private var knownCompletedIds: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            if entitlements.can(.runAgents) {
                inputBar
                Divider().background(Color.white.opacity(0.07))
                jobList
            } else {
                upgradePrompt
            }
        }
        .sheet(item: $detailJob) { job in
            AgentDetailView(jobId: job.id, store: jobStore)
                .frame(width: 660, height: 500)
        }
        .sheet(item: $answeringJob) { job in
            AnswerQuestionsSheet(
                job: job,
                store: jobStore,
                apiKey: miraState.effectiveAPIKey
            )
            .frame(width: 560, height: 460)
        }
        .onAppear {
            knownCompletedIds = Set(jobStore.completedJobs.map(\.id))
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Main text row
            HStack(spacing: 8) {
                Image(systemName: detectedType.icon)
                    .font(.system(size: 11))
                    .foregroundColor(accent.opacity(0.7))
                    .frame(width: 16)

                TextField("What should I build or research?", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .onChange(of: input) { _, newValue in
                        detectedType = AgentJobType.detect(from: newValue)
                    }
                    .onSubmit { submitJob() }
                    .accessibilityLabel("Describe what to build or research")

                if !input.isEmpty && detectedType != .websiteBuilder {
                    Text(detectedType.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(accent.opacity(0.6))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(accent.opacity(0.10))
                        .clipShape(Capsule())
                }

                Button(action: submitJob) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(canSubmit ? accent : .white.opacity(0.15))
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .accessibilityLabel("Submit task")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Expanded website builder controls
            if detectedType == .websiteBuilder && !input.isEmpty {
                websiteBuilderControls
            }
        }
    }

    private var canSubmit: Bool {
        guard !input.isEmpty && miraState.isSignedIn else { return false }
        if detectedType == .websiteBuilder && websiteMode.requiresReferences {
            return !referenceImagePaths.isEmpty
        }
        return true
    }

    @ViewBuilder
    private var websiteBuilderControls: some View {
        VStack(spacing: 8) {
            Divider().background(Color.white.opacity(0.06))

            VStack(alignment: .leading, spacing: 8) {
                // Mode selector
                HStack(spacing: 0) {
                    ForEach(WebsiteBuildMode.allCases, id: \.self) { mode in
                        Button {
                            websiteMode = mode
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 9, weight: .semibold))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(mode.rawValue)
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(mode.tagline)
                                        .font(.system(size: 9))
                                        .opacity(0.65)
                                }
                            }
                            .foregroundColor(websiteMode == mode ? .black : .white.opacity(0.50))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(websiteMode == mode ? accent : Color.white.opacity(0.05))
                        }
                        .buttonStyle(.plain)
                        .clipShape(RoundedRectangle(cornerRadius: 0))
                        .accessibilityLabel("\(mode.rawValue) mode, \(mode.tagline)")
                        .accessibilityAddTraits(websiteMode == mode ? .isSelected : [])
                        if mode != WebsiteBuildMode.allCases.last {
                            Divider().frame(width: 1).background(Color.white.opacity(0.08))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))

                // References section (Pro/Studio)
                if websiteMode != .fast {
                    referencePickerRow
                }

                // Studio gate warning
                if websiteMode == .studio && referenceImagePaths.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(amber)
                        Text("Studio requires design references for premium output")
                            .font(.system(size: 10))
                            .foregroundColor(amber.opacity(0.85))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var referencePickerRow: some View {
        HStack(spacing: 8) {
            // Thumbnails of added images
            if !referenceImagePaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(referenceImagePaths.prefix(5), id: \.self) { path in
                            ZStack(alignment: .topTrailing) {
                                if let img = NSImage(contentsOfFile: path) {
                                    Image(nsImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 32, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                } else {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Color.white.opacity(0.1))
                                        .frame(width: 32, height: 32)
                                }
                                Button {
                                    referenceImagePaths.removeAll { $0 == path }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.7))
                                        .background(Color.black.opacity(0.5))
                                        .clipShape(Circle())
                                        .accessibilityHidden(true)
                                }
                                .buttonStyle(.plain)
                                .offset(x: 4, y: -4)
                                .accessibilityLabel("Remove reference image")
                            }
                        }
                    }
                }
            }

            Spacer()

            Button(action: pickReferenceImages) {
                HStack(spacing: 4) {
                    Image(systemName: referenceImagePaths.isEmpty ? "photo.badge.plus" : "plus.circle")
                        .font(.system(size: 10))
                        .accessibilityHidden(true)
                    Text(referenceImagePaths.isEmpty ? "Add References" : "Add More")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(accent.opacity(0.85))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(accent.opacity(0.10))
                .clipShape(Capsule())
            }
            .accessibilityLabel(referenceImagePaths.isEmpty ? "Add design references" : "Add more design references")
            .buttonStyle(.plain)
        }

        if referenceImagePaths.isEmpty {
            Text("Drop Framer templates, Dribbble shots, or screenshots to guide the design")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.28))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Job list

    @ViewBuilder
    private var jobList: some View {
        let confirmation = jobStore.confirmationPendingJobs
        let variants     = jobStore.variantSelectionJobs
        let blocked      = jobStore.blockedJobs
        let waiting      = jobStore.waitingForInputJobs
        let active       = jobStore.activeJobs
        let completed    = jobStore.completedJobs

        if confirmation.isEmpty && variants.isEmpty && blocked.isEmpty && waiting.isEmpty && active.isEmpty && completed.isEmpty {
            emptyState
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {

                    // Awaiting Approval — highest priority
                    // .id scoped per card type prevents LazyVStack from recycling
                    // RunningJobCard bodies when a job transitions into this section.
                    if !confirmation.isEmpty {
                        Section {
                            ForEach(confirmation) { job in
                                WaitingForConfirmationCard(
                                    job: job,
                                    onApprove: { jobStore.approveConfirmation(id: job.id) },
                                    onDeny:    { jobStore.denyConfirmation(id: job.id) }
                                )
                                .id("confirm-\(job.id)")
                                .padding(.horizontal, 12)
                                .padding(.top, 6)
                            }
                        } header: {
                            sectionHeader("Awaiting Approval", count: confirmation.count, color: amber)
                        }
                    }

                    // Variant Selection — Studio mode: user picks from 3 generated designs
                    if !variants.isEmpty {
                        Section {
                            ForEach(variants) { job in
                                VariantPickerCard(job: job, store: jobStore)
                                    .id("variant-\(job.id)")
                                    .padding(.horizontal, 12)
                                    .padding(.top, 6)
                            }
                        } header: {
                            sectionHeader("Choose a Design", count: variants.count, color: amber)
                        }
                    }

                    // Blocked — permission or tool missing
                    if !blocked.isEmpty {
                        Section {
                            ForEach(blocked) { job in
                                BlockedJobCard(job: job, store: jobStore)
                                    .id("blocked-\(job.id)")
                                    .padding(.horizontal, 12)
                                    .padding(.top, 6)
                            }
                        } header: {
                            sectionHeader("Blocked", count: blocked.count, color: red)
                        }
                    }

                    // Waiting for Input
                    if !waiting.isEmpty {
                        Section {
                            ForEach(waiting) { job in
                                WaitingForInputCard(
                                    job: job,
                                    onAnswer: { answeringJob = job },
                                    onCancel: { jobStore.cancelJob(id: job.id) }
                                )
                                .id("input-\(job.id)")
                                .padding(.horizontal, 12)
                                .padding(.top, 6)
                            }
                        } header: {
                            sectionHeader("Waiting for Input", count: waiting.count, color: orange)
                        }
                    }

                    // Running / Queued / Preparing / Reading / Writing
                    if !active.isEmpty {
                        Section {
                            ForEach(active) { job in
                                RunningJobCard(job: job, store: jobStore)
                                    .id("run-\(job.id)")
                                    .padding(.horizontal, 12)
                                    .padding(.top, 6)
                            }
                        } header: {
                            sectionHeader("Running", count: active.count, color: green)
                        }
                    }

                    if !completed.isEmpty {
                        let newIds = Set(completed.map(\.id)).subtracting(knownCompletedIds)
                        Section {
                            ForEach(completed) { job in
                                CompletedJobCard(job: job, store: jobStore, isNew: newIds.contains(job.id))
                                    .padding(.horizontal, 12)
                                    .padding(.top, 6)
                                    .onTapGesture { detailJob = job }
                            }
                        } header: {
                            sectionHeader("Completed", count: completed.count, color: .white.opacity(0.3))
                        }
                        .onChange(of: completed.count) {
                            knownCompletedIds = Set(completed.map(\.id))
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(color.opacity(0.5))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.95))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.08))
            Text("No agent jobs yet")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.25))
            Text("Type a task above to start a background agent")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.15))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Upgrade prompt

    private var upgradePrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 26))
                .foregroundColor(accent.opacity(0.5))
            Text("Agents require Pro")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.80))
            Text("Run background agents that build websites, research topics, generate content, and more — without blocking your chat.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button {
                // Opens the pricing page — replace with real URL
                NSWorkspace.shared.open(URL(string: "https://mira.ai/pricing")!)
            } label: {
                Text("Upgrade to Pro")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Submit

    private func submitJob() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, miraState.isSignedIn else { return }
        let isWebsite = detectedType == .websiteBuilder
        let mode = isWebsite ? websiteMode : nil
        let refs = isWebsite ? referenceImagePaths : []
        input = ""
        detectedType = .custom
        referenceImagePaths = []
        jobStore.submitJob(prompt: prompt, apiKey: miraState.effectiveAPIKey,
                           buildMode: mode, referenceImagePaths: refs)
    }

    private func pickReferenceImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.title = "Select Design Reference Images"
        panel.message = "Choose screenshots, Framer templates, Dribbble shots, or any design references"
        if panel.runModal() == .OK {
            let newPaths = panel.urls.map(\.path)
            referenceImagePaths = Array(Set(referenceImagePaths + newPaths)).prefix(5).map { $0 }
        }
    }
}

// MARK: - Running Job Card (Agent Rail 2.0)

private struct RunningJobCard: View {
    let job: AgentJob
    @ObservedObject var store: AgentJobStore
    @State private var pulse = false
    @State private var expandedStepIndex: Int? = nil

    private var liveJob: AgentJob { store.job(id: job.id) ?? job }

    var body: some View {
        let j = liveJob
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(green.opacity(0.12)).frame(width: 26, height: 26)
                    Circle().fill(green.opacity(0.22)).frame(width: 26, height: 26)
                        .scaleEffect(pulse ? 1.5 : 1.0).opacity(pulse ? 0 : 1)
                    Image(systemName: j.type.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(green)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                        pulse = true
                    }
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(j.type.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.90))
                    Text(j.prompt)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.28))
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(j.progress * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(green.opacity(0.80))
                        .accessibilityLabel("Progress: \(Int(j.progress * 100)) percent")
                    Text(timeLabel(j))
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.22))
                }
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

            // ── Thin progress bar ────────────────────────────────────
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.06).frame(height: 2)
                    green.frame(width: geo.size.width * j.progress, height: 2)
                        .animation(.linear(duration: 0.4), value: j.progress)
                }
            }
            .frame(height: 2)
            .accessibilityHidden(true)

            // ── Step timeline ────────────────────────────────────────
            if !j.steps.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(j.steps.enumerated()), id: \.element.id) { idx, step in
                        StepRow(
                            step: step,
                            isExpanded: expandedStepIndex == idx,
                            onTap: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    expandedStepIndex = expandedStepIndex == idx ? nil : idx
                                }
                            }
                        )
                    }
                }
                .padding(.top, 6).padding(.bottom, 4)
            }
        }
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(green.opacity(0.15), lineWidth: 1))
        .accessibilityLabel(runningA11yLabel(liveJob))
    }

    private func runningA11yLabel(_ j: AgentJob) -> String {
        let stepDesc: String
        if let running = j.steps.first(where: { $0.status == .running }),
           let idx = j.steps.firstIndex(where: { $0.id == running.id }) {
            stepDesc = "Step \(idx + 1) of \(j.steps.count): \(running.title)."
        } else {
            stepDesc = j.currentStep.isEmpty ? "" : "\(j.currentStep)."
        }
        return "\(j.type.rawValue), running. \(stepDesc) \(Int(j.progress * 100)) percent complete."
    }

    private func timeLabel(_ j: AgentJob) -> String {
        if let remaining = j.estimatedTimeRemaining {
            let secs = Int(remaining)
            return secs > 60 ? "~\(secs / 60)m left" : "~\(secs)s left"
        }
        if let start = j.startedAt {
            let elapsed = Int(Date().timeIntervalSince(start))
            return elapsed > 60 ? "\(elapsed / 60)m" : "\(elapsed)s"
        }
        return "Starting…"
    }
}

// MARK: - Step Row (Agent Rail 2.0)

private struct StepRow: View {
    let step: AgentJobStep
    let isExpanded: Bool
    let onTap: () -> Void

    private var statusIcon: String {
        switch step.status {
        case .completed:                 return "checkmark"
        case .running, .writing:         return "arrow.right"
        case .failed:                    return "xmark"
        case .waitingForInput,
             .waitingForConfirmation,
             .waitingForVariantSelection: return "pause.fill"
        default:                         return "circle"
        }
    }

    private var statusColor: Color {
        switch step.status {
        case .completed:                  return green
        case .running, .writing:          return accent
        case .failed:                     return red
        case .waitingForInput,
             .waitingForConfirmation,
             .waitingForVariantSelection: return amber
        default:                          return .white.opacity(0.18)
        }
    }

    private var isPending: Bool {
        step.status == .queued || step.status == .preparing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                HStack(alignment: .center, spacing: 8) {
                    // Status icon column (fixed width for alignment)
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(isPending ? 0.06 : 0.14))
                            .frame(width: 16, height: 16)
                        Image(systemName: statusIcon)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(statusColor.opacity(isPending ? 0.35 : 1.0))
                    }
                    .frame(width: 16)

                    // Step title
                    Text(step.title)
                        .font(.system(size: 11, weight: step.status == .running ? .medium : .regular))
                        .foregroundColor(isPending ? .white.opacity(0.22) : .white.opacity(step.status == .completed ? 0.42 : 0.82))
                        .lineLimit(1)

                    Spacer()

                    // Log indicator (if has log and is collapsed)
                    if step.log != nil && !isExpanded {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.18))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(step.log == nil)

            // Expanded log
            if isExpanded, let log = step.log {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(log.components(separatedBy: "\n").filter { !$0.isEmpty }, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.40))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 36)
                .padding(.trailing, 12)
                .padding(.bottom, 5)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Completed Job Card

private struct CompletedJobCard: View {
    let job: AgentJob
    @ObservedObject var store: AgentJobStore
    let isNew: Bool
    @AccessibilityFocusState private var cardFocused: Bool

    private var statusColor: Color {
        switch job.status {
        case .completed: return green
        case .failed:    return red
        case .cancelled: return .white.opacity(0.3)
        default:         return accent
        }
    }

    private var statusIcon: String {
        switch job.status {
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        default:         return "circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: job.type.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(statusColor)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(job.type.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                    Text(job.result?.summary ?? job.errorMessage ?? job.prompt)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.38))
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 11))
                        .foregroundColor(statusColor)
                        .accessibilityHidden(true)
                    Text(job.relativeTime)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.22))
                }
            }

            // Preview thumbnail for completed website builds
            if job.status == .completed && job.type == .websiteBuilder,
               let previewPath = job.result?.previewImagePath,
               let img = NSImage(contentsOfFile: previewPath) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .accessibilityLabel("Website preview image")
            }

            // Critic scorecard for completed website builds
            if job.status == .completed && job.type == .websiteBuilder,
               let criticJSON = job.result?.metadata["criticReport"],
               let data = criticJSON.data(using: .utf8),
               let report = try? JSONDecoder().decode(CriticReport.self, from: data) {
                CriticScorecardView(report: report)
            }

            // Action bubbles (completed only)
            if job.status == .completed {
                actionBubbles
            }

            // Star rating for completed website builds
            if job.status == .completed && job.type == .websiteBuilder {
                StarRatingView(job: job, store: store)
            }
        }
        .padding(12)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .accessibilityHint(job.status == .completed ? "Tap to view details" : "")
        .accessibilityFocused($cardFocused)
        .onAppear {
            guard isNew else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                cardFocused = true
            }
        }
    }

    @ViewBuilder
    private var actionBubbles: some View {
        let actions = job.actions
        if !actions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(actions.prefix(4)) { action in
                        ActionBubble(action: action, job: job)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }
}

// MARK: - Action Bubble

private struct ActionBubble: View {
    let action: AgentJobAction
    let job: AgentJob

    var body: some View {
        Button {
            handleAction(action.identifier)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: action.icon)
                    .font(.system(size: 10, weight: .medium))
                    .accessibilityHidden(true)
                Text(action.title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.65))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.07))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
    }

    private func handleAction(_ identifier: String) {
        switch identifier {
        case "open_browser":
            if let path = job.result?.outputPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        case "open_report", "open_file", "view_result":
            if let path = job.result?.outputPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        case "export_code", "export_pdf", "export_source":
            if let path = job.result?.outputPath {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        case "open_project":
            NotificationCenter.default.post(name: .miraTabSelected, object: IslandTab.home)
        case "open_project_finder":
            if let dir = job.result?.metadata["outputDirectory"] {
                NSWorkspace.shared.open(URL(fileURLWithPath: dir))
            }
        case "improve_website":
            let apiKey = UserDefaults.standard.string(forKey: "mira_api_key") ?? ""
            guard !apiKey.isEmpty else { break }
            if let entry = OutputStore.shared.entries.first(where: { $0.sourceJobId == job.id }) {
                AgentJobStore.shared.submitImprovementJob(outputEntryId: entry.id, apiKey: apiKey)
            }
        case "suggest_edits":
            NotificationCenter.default.post(
                name: .miraChipPromptSelected,
                object: nil,
                userInfo: ["prompt": "Suggest improvements for the \(job.type.rawValue.lowercased()) I just built: \(job.prompt)"]
            )
        case "summarize":
            NotificationCenter.default.post(
                name: .miraChipPromptSelected,
                object: nil,
                userInfo: ["prompt": "Create a concise executive summary of the research report: \(job.result?.summary ?? job.prompt)"]
            )
        default:
            break
        }
    }
}

// MARK: - Critic Scorecard View

private struct CriticScorecardView: View {
    let report: CriticReport

    private func scoreColor(_ score: Int) -> Color {
        if score >= 8 { return green }
        if score >= 6 { return amber }
        return red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Quality Audit")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
                Spacer()
                Text("\(report.overallScore)/10")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(scoreColor(report.overallScore))
            }
            HStack(spacing: 4) {
                ForEach([
                    ("Visual",   report.visualQuality),
                    ("Convert",  report.conversionPotential),
                    ("Mobile",   report.mobileExperience),
                    ("Access",   report.accessibility),
                    ("Brand",    report.brandConsistency),
                ], id: \.0) { label, score in
                    VStack(spacing: 2) {
                        Text("\(score)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(scoreColor(score))
                        Text(label)
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.28))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(scoreColor(score).opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Agent Detail View

struct AgentDetailView: View {
    let jobId: UUID
    @ObservedObject var store: AgentJobStore
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var titleFocused: Bool

    private var job: AgentJob? { store.job(id: jobId) }

    var body: some View {
        if let job = job {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    detailHeader(job)
                    Divider().background(Color.white.opacity(0.07))
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 16) {
                            if let result = job.result {
                                resultSection(result)
                            }
                            if let err = job.errorMessage {
                                errorSection(err)
                            }
                            stepsTimeline(job.steps)
                            if job.status == .completed {
                                actionsSection(job)
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    titleFocused = true
                }
            }
        }
    }

    private func detailHeader(_ job: AgentJob) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(accent.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: job.type.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(job.type.rawValue)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .accessibilityFocused($titleFocused)
                Text(job.prompt)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .lineLimit(1)
            }

            Spacer()

            statusPill(job.status)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.30))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func statusPill(_ status: AgentJobStatus) -> some View {
        let color: Color = {
            switch status {
            case .completed:                        return green
            case .running, .preparing,
                 .reading, .writing:                return accent
            case .failed:                           return red
            case .cancelled:                        return .white.opacity(0.3)
            case .queued, .waitingForInput:              return orange
            case .waitingForConfirmation,
                 .waitingForVariantSelection:        return amber
            case .blockedPermission, .blockedTool:  return red
            }
        }()
        return Text(status.displayName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
    }

    private func resultSection(_ result: AgentJobResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Result")
            Text(result.summary)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.80))
                .fixedSize(horizontal: false, vertical: true)

            if let path = result.outputPath {
                HStack(spacing: 6) {
                    Image(systemName: "doc")
                        .font(.system(size: 10))
                        .foregroundColor(accent.opacity(0.6))
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundColor(accent.opacity(0.8))
                        .lineLimit(1)
                    Spacer()
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(accent)
                        .buttonStyle(.plain)
                }
                .padding(8)
                .background(accent.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func errorSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Error")
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(red.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .background(red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private func stepsTimeline(_ steps: [AgentJobStep]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            label("Timeline")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 0) {
                            stepDot(step.status)
                            if idx < steps.count - 1 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.08))
                                    .frame(width: 1, height: 20)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(.system(size: 12))
                                .foregroundColor(stepTextColor(step.status))
                            if let log = step.log {
                                Text(log)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.25))
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        if let completed = step.completedAt, let started = step.startedAt {
                            Text("\(Int(completed.timeIntervalSince(started)))s")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.20))
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private func stepDot(_ status: AgentJobStatus) -> some View {
        let color: Color = {
            switch status {
            case .completed:                        return green
            case .running, .preparing,
                 .reading, .writing:                return accent
            case .failed, .blockedPermission,
                 .blockedTool:                      return red
            case .waitingForConfirmation:           return amber
            case .waitingForInput:                  return orange
            default:                               return .white.opacity(0.15)
            }
        }()
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .padding(.top, 4)
    }

    private func stepTextColor(_ status: AgentJobStatus) -> Color {
        switch status {
        case .completed:                        return .white.opacity(0.75)
        case .running, .preparing,
             .reading, .writing:                return .white
        case .failed, .blockedPermission,
             .blockedTool:                      return red
        case .waitingForConfirmation:           return amber
        case .waitingForInput:                  return orange
        default:                               return .white.opacity(0.30)
        }
    }

    private func actionsSection(_ job: AgentJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Actions")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(job.actions) { action in
                    ActionBubble(action: action, job: job)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(surface2)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white.opacity(0.25))
            .kerning(0.8)
    }
}

// MARK: - Waiting For Input Card

private struct WaitingForInputCard: View {
    let job: AgentJob
    let onAnswer: () -> Void
    let onCancel: () -> Void

    private let orangeColor = Color(red: 1.0, green: 0.60, blue: 0.20)
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(orangeColor.opacity(0.12))
                        .frame(width: 26, height: 26)
                    Circle()
                        .fill(orangeColor.opacity(0.20))
                        .frame(width: 26, height: 26)
                        .scaleEffect(pulse ? 1.5 : 1.0)
                        .opacity(pulse ? 0 : 1)
                    Image(systemName: job.type.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(orangeColor)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                        pulse = true
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(job.type.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.90))
                    Text("Information needed to continue")
                        .font(.system(size: 11))
                        .foregroundColor(orangeColor.opacity(0.75))
                }

                Spacer()

                Text(job.relativeTime)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.22))
            }

            // Score badge if available
            if let readiness = job.buildReadiness {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 9))
                        .foregroundColor(orangeColor.opacity(0.6))
                    Text("Readiness: \(Int(readiness.score))% — \(readiness.summary)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }

            // Requirements list
            if let readiness = job.buildReadiness, !readiness.missingRequirements.isEmpty {
                Divider().background(Color.white.opacity(0.06))
                VStack(alignment: .leading, spacing: 5) {
                    Text("MISSING INFORMATION")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.25))
                        .kerning(0.8)
                    ForEach(Array(readiness.missingRequirements.prefix(5).enumerated()), id: \.offset) { idx, question in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(idx + 1).")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(orangeColor.opacity(0.5))
                                .frame(width: 14, alignment: .trailing)
                            Text(question)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.65))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            // Action buttons
            HStack(spacing: 8) {
                Button(action: onAnswer) {
                    HStack(spacing: 4) {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 10))
                        Text("Answer Questions")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(orangeColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.30))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(red: 0.13, green: 0.11, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(orangeColor.opacity(0.20), lineWidth: 1)
        )
    }
}

// MARK: - Answer Questions Sheet

struct AnswerQuestionsSheet: View {
    let job: AgentJob
    let store: AgentJobStore
    let apiKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var answers = ""
    @AccessibilityFocusState private var editorFocused: Bool

    private let orangeColor = Color(red: 1.0, green: 0.60, blue: 0.20)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(orangeColor.opacity(0.15))
                            .frame(width: 32, height: 32)
                        Image(systemName: job.type.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(orangeColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Answer to continue")
                            .accessibilityAddTraits(.isHeader)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text(job.type.rawValue)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.30))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)

                Divider().background(Color.white.opacity(0.07))

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        // Questions
                        if let readiness = job.buildReadiness, !readiness.missingRequirements.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("QUESTIONS")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.25))
                                    .kerning(0.8)
                                ForEach(Array(readiness.missingRequirements.enumerated()), id: \.offset) { idx, q in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(idx + 1).")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(orangeColor.opacity(0.6))
                                            .frame(width: 18, alignment: .trailing)
                                        Text(q)
                                            .font(.system(size: 12))
                                            .foregroundColor(.white.opacity(0.70))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }

                        // Answer input
                        VStack(alignment: .leading, spacing: 6) {
                            Text("YOUR ANSWERS")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.white.opacity(0.25))
                                .kerning(0.8)
                            TextEditor(text: $answers)
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .scrollContentBackground(.hidden)
                                .background(Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .frame(minHeight: 120)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                )
                                .accessibilityFocused($editorFocused)
                            if answers.isEmpty {
                                Text("Type your answers here — address each question above…")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.18))
                                    .padding(.top, -100)
                                    .padding(.leading, 6)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .padding(20)
                }

                Divider().background(Color.white.opacity(0.07))

                // Footer buttons
                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Text("Cancel")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.35))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        let trimmed = answers.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        store.provideInput(id: job.id, answers: trimmed, apiKey: apiKey)
                        dismiss()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 12))
                            Text("Continue Building")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(answers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? orangeColor.opacity(0.3) : orangeColor)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(answers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(20)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                editorFocused = true
            }
        }
    }
}

// MARK: - Waiting For Confirmation Card

private struct WaitingForConfirmationCard: View {
    let job: AgentJob
    let onApprove: () -> Void
    let onDeny: () -> Void

    @State private var pulse = false
    @AccessibilityFocusState private var approveFocused: Bool

    var body: some View {
        let req = job.confirmationRequest
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(amber.opacity(0.12))
                        .frame(width: 26, height: 26)
                    Circle()
                        .fill(amber.opacity(0.22))
                        .frame(width: 26, height: 26)
                        .scaleEffect(pulse ? 1.5 : 1.0)
                        .opacity(pulse ? 0 : 1)
                    Image(systemName: job.type.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(amber)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                        pulse = true
                    }
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(req?.title ?? job.type.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.90))
                    Text("Approval required to continue")
                        .font(.system(size: 11))
                        .foregroundColor(amber.opacity(0.75))
                }

                Spacer()

                Text(job.relativeTime)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.22))
            }

            // Summary (1 line) + risk badge inline with approve/deny
            if let req = req {
                Text(req.summary)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.50))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Risk badge + Approve / Deny on same row — keeps card compact
            HStack(spacing: 8) {
                if let req = req {
                    Image(systemName: req.riskLevel.icon)
                        .font(.system(size: 10))
                        .foregroundColor(riskColor(req.riskLevel))
                        .accessibilityHidden(true)
                    Text(req.riskLevel.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(riskColor(req.riskLevel))
                        .accessibilityLabel("\(req.riskLevel.displayName) risk")
                }

                Spacer()

                Button(action: onDeny) {
                    Text(req?.denyLabel ?? "Deny")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.40))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(req?.denyLabel ?? "Deny")
                .accessibilityHint("Cancels this action")

                Button(action: onApprove) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .accessibilityHidden(true)
                        Text(req?.approveLabel ?? "Approve")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(amber)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(req?.approveLabel ?? "Approve")
                .accessibilityHint("Confirms and continues the action")
                .accessibilityFocused($approveFocused)
            }
        }
        .padding(12)
        .background(Color(red: 0.12, green: 0.11, blue: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(amber.opacity(0.25), lineWidth: 1)
        )
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                approveFocused = true
            }
        }
    }

    private func riskColor(_ level: RiskLevel) -> Color {
        switch level {
        case .low:    return green
        case .medium: return orange
        case .high:   return red
        }
    }
}

// MARK: - Blocked Job Card

private struct BlockedJobCard: View {
    let job: AgentJob
    @ObservedObject var store: AgentJobStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(red.opacity(0.12))
                        .frame(width: 26, height: 26)
                    Image(systemName: job.status == .blockedPermission ? "lock.fill" : "wrench.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(red)
                }


                VStack(alignment: .leading, spacing: 1) {
                    Text(job.type.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.90))
                    Text(job.status == .blockedPermission ? "Permission required" : "Tool unavailable")
                        .font(.system(size: 11))
                        .foregroundColor(red.opacity(0.75))
                }

                Spacer()

                Button { store.cancelJob(id: job.id) } label: {
                    Text("Dismiss")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.28))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if let error = job.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.50))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(12)
        .background(Color(red: 0.12, green: 0.09, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(red.opacity(0.18), lineWidth: 1)
        )
    }
}

// MARK: - Variant Picker Card

private struct VariantPickerCard: View {
    let job: AgentJob
    @ObservedObject var store: AgentJobStore

    private var variants: [VariantOption] { job.variantOptions ?? [] }
    private var previews: [NSImage?] { store.variantPreviews(for: job.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11))
                    .foregroundColor(amber)
                Text("Choose a design")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.90))
                Spacer()
                Text("\(variants.count) variants ready")
                    .font(.system(size: 10))
                    .foregroundColor(amber.opacity(0.70))
            }

            Text(job.prompt.prefix(70) + (job.prompt.count > 70 ? "…" : ""))
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.32))
                .lineLimit(1)

            if variants.isEmpty {
                HStack { Spacer(); ProgressView().scaleEffect(0.7); Spacer() }
                    .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(variants.enumerated()), id: \.offset) { idx, variant in
                            VariantThumbnail(
                                name: variant.name,
                                preview: idx < previews.count ? previews[idx] : nil
                            ) {
                                store.selectVariant(id: job.id, variantIndex: idx)
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }

            Button { store.cancelJob(id: job.id) } label: {
                Text("Cancel")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(amber.opacity(0.25), lineWidth: 1))
    }
}

private struct VariantThumbnail: View {
    let name: String
    let preview: NSImage?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                Group {
                    if let img = preview {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.white.opacity(0.05)
                            ProgressView().scaleEffect(0.6)
                        }
                    }
                }
                .frame(width: 170, height: 107)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))

                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Star Rating View

private struct StarRatingView: View {
    let job: AgentJob
    @ObservedObject var store: AgentJobStore
    @State private var rating: Int = 0
    @State private var savedLabel: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text("Rate:")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.28))

            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundColor(star <= rating ? amber : .white.opacity(0.18))
                        .onTapGesture {
                            guard rating != star else { return }
                            rating = star
                            QualityStore.shared.record(job: job, rating: star)
                            if star == 5 {
                                store.approveAsExample(jobId: job.id)
                                withAnimation { savedLabel = "Saved as example" }
                            }
                        }
                }
            }

            if let label = savedLabel {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(green.opacity(0.85))
                    .transition(.opacity)
            }
        }
        .onAppear { rating = QualityStore.shared.rating(for: job.id) }
    }
}
