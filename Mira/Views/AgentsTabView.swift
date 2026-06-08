import SwiftUI

private let surface  = Color(red: 0.11, green: 0.11, blue: 0.13)
private let surface2 = Color(red: 0.14, green: 0.14, blue: 0.17)
private let accent   = Color(red: 0.29, green: 0.62, blue: 1.0)
private let green    = Color(red: 0.20, green: 0.84, blue: 0.29)
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
    @State private var answeringJob: AgentJob? = nil  // drives the answer sheet
    @State private var detectedType: AgentJobType = .custom

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
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            // Job type indicator
            Image(systemName: detectedType.icon)
                .font(.system(size: 11))
                .foregroundColor(accent.opacity(0.7))
                .frame(width: 16)

            TextField("What should I build or research?", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .onChange(of: input) { newValue in
                    detectedType = AgentJobType.detect(from: newValue)
                }
                .onSubmit { submitJob() }

            if !input.isEmpty {
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
                    .foregroundColor(input.isEmpty ? .white.opacity(0.15) : accent)
            }
            .buttonStyle(.plain)
            .disabled(input.isEmpty || miraState.effectiveAPIKey.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Job list

    @ViewBuilder
    private var jobList: some View {
        let active    = jobStore.runningJobs.filter { $0.status != .waitingForInput }
        let waiting   = jobStore.runningJobs.filter { $0.status == .waitingForInput }
        let completed = jobStore.completedJobs

        if active.isEmpty && waiting.isEmpty && completed.isEmpty {
            emptyState
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    // Waiting for Input — highest priority, shown first
                    if !waiting.isEmpty {
                        Section {
                            ForEach(waiting) { job in
                                WaitingForInputCard(job: job, onAnswer: { answeringJob = job }, onCancel: { jobStore.cancelJob(id: job.id) })
                                    .padding(.horizontal, 12)
                                    .padding(.top, 6)
                            }
                        } header: {
                            sectionHeader("Waiting for Input", count: waiting.count, color: orange)
                        }
                    }

                    // Running / Queued
                    if !active.isEmpty {
                        Section {
                            ForEach(active) { job in
                                RunningJobCard(job: job, store: jobStore)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 6)
                            }
                        } header: {
                            sectionHeader("Running", count: active.count, color: green)
                        }
                    }

                    if !completed.isEmpty {
                        Section {
                            ForEach(completed) { job in
                                CompletedJobCard(job: job)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 6)
                                    .onTapGesture { detailJob = job }
                            }
                        } header: {
                            sectionHeader("Completed", count: completed.count, color: .white.opacity(0.3))
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
        guard !prompt.isEmpty, !miraState.effectiveAPIKey.isEmpty else { return }
        input = ""
        detectedType = .custom
        jobStore.submitJob(prompt: prompt, apiKey: miraState.effectiveAPIKey)
    }
}

// MARK: - Running Job Card

private struct RunningJobCard: View {
    let job: AgentJob
    @ObservedObject var store: AgentJobStore
    @State private var pulse = false

    private var liveJob: AgentJob? { store.job(id: job.id) }

    var body: some View {
        let j = liveJob ?? job
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(green.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Circle()
                        .fill(green.opacity(0.25))
                        .frame(width: 26, height: 26)
                        .scaleEffect(pulse ? 1.4 : 1.0)
                        .opacity(pulse ? 0 : 1)
                    Image(systemName: j.type.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(green)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                        pulse = true
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(j.type.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.90))
                    Text(j.currentStep)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.40))
                }

                Spacer()

                Text(timeLabel(j))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(green)
                        .frame(width: geo.size.width * j.progress, height: 3)
                        .animation(.linear(duration: 0.4), value: j.progress)
                }
            }
            .frame(height: 3)

            HStack {
                Text(j.prompt)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
                    .lineLimit(1)
                Spacer()
                Text("\(Int(j.progress * 100))%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(green.opacity(0.7))
            }
        }
        .padding(12)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(green.opacity(0.15), lineWidth: 1)
        )
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

// MARK: - Completed Job Card

private struct CompletedJobCard: View {
    let job: AgentJob

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
                    Text(job.relativeTime)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.22))
                }
            }

            // Action bubbles (completed only)
            if job.status == .completed {
                actionBubbles
            }
        }
        .padding(12)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
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
                Text(action.title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.65))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.07))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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
            if let dir = job.result?.metadata["outputDirectory"] {
                NSWorkspace.shared.open(URL(fileURLWithPath: dir))
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

// MARK: - Agent Detail View

struct AgentDetailView: View {
    let jobId: UUID
    @ObservedObject var store: AgentJobStore
    @Environment(\.dismiss) private var dismiss

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
        let color: Color
        switch status {
        case .completed:       color = green
        case .running:         color = accent
        case .failed:          color = red
        case .cancelled:       color = .white.opacity(0.3)
        case .queued:          color = orange
        case .waitingForInput: color = orange
        }
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
        let color: Color
        switch status {
        case .completed: color = green
        case .running:   color = accent
        case .failed:    color = red
        default:         color = .white.opacity(0.15)
        }
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .padding(.top, 4)
    }

    private func stepTextColor(_ status: AgentJobStatus) -> Color {
        switch status {
        case .completed: return .white.opacity(0.75)
        case .running:   return .white
        case .failed:    return red
        default:         return .white.opacity(0.30)
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
    }
}
