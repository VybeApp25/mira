import SwiftUI

private let surface = Color(red: 0.11, green: 0.11, blue: 0.13)
private let accent  = Color(red: 0.29, green: 0.62, blue: 1.0)

struct AgentsTabView: View {
    @ObservedObject var taskStore: AgentTaskStore
    @ObservedObject var miraState: MiraState
    @ObservedObject var overlay: OverlayWindowController
    let capture: ScreenCaptureService
    @ObservedObject var voice: VoiceService

    @State private var input = ""
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 0) {
            agentInputBar
            Divider().background(Color.white.opacity(0.07))
            taskList
        }
    }

    // MARK: - Input bar

    private var agentInputBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11))
                .foregroundColor(accent.opacity(0.7))

            TextField("Hey Mira Agent, do something...", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .onSubmit { Task { await runAgentTask() } }

            if isRunning {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .tint(accent)
            } else {
                Button(action: { Task { await runAgentTask() } }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(input.isEmpty ? .white.opacity(0.15) : accent)
                }
                .buttonStyle(.plain)
                .disabled(input.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Task list

    @ViewBuilder
    private var taskList: some View {
        if taskStore.tasks.isEmpty {
            emptyState
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(taskStore.tasks) { task in
                        taskRow(task)
                    }
                }
                .padding(12)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.1))
            Text("No agent tasks yet")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.3))
            Text("Type above or say \"Hey Mira Agent...\"")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func taskRow(_ task: AgentTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Tool icon
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(accent.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: task.toolIcon)
                    .font(.system(size: 12))
                    .foregroundColor(accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(task.prompt)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                Text(task.reply)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "clock.fill")
                    .font(.system(size: 11))
                    .foregroundColor(task.isCompleted
                        ? Color(red: 0.20, green: 0.84, blue: 0.29)
                        : .orange)
                Text(task.relativeTime)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .padding(10)
        .background(surface)
        .cornerRadius(10)
    }

    // MARK: - Run task

    @MainActor
    private func runAgentTask() async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning, !miraState.effectiveAPIKey.isEmpty else { return }

        input = ""
        isRunning = true

        // Journal every agent run against the most recently active project so
        // hasActiveUserSession is accurate and Phase 11 scheduler guards hold.
        let activeProjectId = ProjectEngine.shared.activeProjects.first?.id
        if let pid = activeProjectId {
            ProjectEngine.shared.startSession(projectId: pid, trigger: .userCommand)
        }

        do {
            let result = try await AgentService.shared.run(prompt: prompt, claudeApiKey: miraState.effectiveAPIKey)
            if let pid = activeProjectId {
                ProjectEngine.shared.endSession(projectId: pid,
                                                summary: result.reply.isEmpty ? nil : result.reply)
            }
            taskStore.add(
                prompt: prompt,
                reply: result.reply,
                toolsUsed: result.toolsUsed,
                completed: result.requiresConfirmation == nil
            )
        } catch {
            if let pid = activeProjectId {
                ProjectEngine.shared.endSession(projectId: pid, summary: nil)
            }
            taskStore.add(prompt: prompt, reply: "Error: \(error.localizedDescription)", toolsUsed: [], completed: false)
        }

        isRunning = false
    }
}
