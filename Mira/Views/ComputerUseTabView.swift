import SwiftUI

struct ComputerUseTabView: View {
    let miraState: MiraState

    @ObservedObject private var orchestrator = ComputerUseOrchestrator.shared
    @ObservedObject private var drawn = PendingDrawnContextService.shared
    @State private var taskText = ""
    @State private var handoffPrompt = ""
    @State private var showHandoffSheet = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider().opacity(0.15)
            contentArea
            Divider().opacity(0.15)
            inputBar
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Computer Use")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            if orchestrator.isRunning {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.white)
                Button("Stop") { orchestrator.stop() }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.red)
                    .buttonStyle(.plain)
            }
            Button(action: startDraw) {
                Label("Draw", systemImage: "pencil.and.scribble")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(drawn.hasPending ? Color(DS.Colors.accent) : .secondary)
            }
            .buttonStyle(.plain)
            .help("Draw on your screen to mark where Mira should act, then type the task")

            Button(action: startHandoff) {
                Label("Handoff", systemImage: "crop")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Select a screen region and ask Claude about it")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        if orchestrator.steps.isEmpty && !orchestrator.isRunning && orchestrator.result.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Steps log
                        ForEach(orchestrator.steps) { step in
                            StepRow(step: step)
                                .id(step.id)
                        }
                        // Running indicator
                        if orchestrator.isRunning {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.5).tint(.secondary)
                                Text("Claude is working…")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .id("spinner")
                        }
                        // Result
                        if !orchestrator.result.isEmpty {
                            resultBubble
                        }
                    }
                }
                .onChange(of: orchestrator.steps.count) { _, _ in
                    if let last = orchestrator.steps.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: orchestrator.isRunning) { _, running in
                    if running { withAnimation { proxy.scrollTo("spinner", anchor: .bottom) } }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Type a task and Mira will control your Mac")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text("Examples:\n• Open Safari and go to apple.com\n• Search for flights to NYC\n• Summarize my unread emails")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var resultBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("Done").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
            }
            Text(orchestrator.result)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 6) {
            if drawn.hasPending {
                HStack(spacing: 6) {
                    Image(systemName: "pencil.and.scribble")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(DS.Colors.accent))
                    Text("Marks attached — they'll target your task")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button { drawn.clear() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Discard the drawn marks")
                }
                .padding(.horizontal, 4)
            }
            inputRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Describe what to do on your Mac…", text: $taskText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...4)
                .focused($fieldFocused)
                .onSubmit { submit() }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.07))
                .cornerRadius(8)

            Button(action: submit) {
                Image(systemName: orchestrator.isRunning ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(orchestrator.isRunning ? .red : (taskText.isEmpty ? .secondary : .white))
            }
            .buttonStyle(.plain)
            .disabled(!orchestrator.isRunning && taskText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Actions

    private func submit() {
        if orchestrator.isRunning { orchestrator.stop(); return }
        let task = taskText.trimmingCharacters(in: .whitespaces)
        guard !task.isEmpty else { return }
        taskText = ""
        let ctx = drawn.pop()   // attach any drawn spatial context to this task
        Task { await orchestrator.run(task: task, apiKey: miraState.effectiveAPIKey, drawn: ctx) }
    }

    private func startDraw() {
        ScreenDrawController.shared.begin(mode: .standalone)
    }

    private func startHandoff() {
        HandoffService.shared.beginRegionSelect { [miraState] result in
            Task {
                await ComputerUseOrchestrator.shared.analyzeHandoff(
                    image: result.image,
                    prompt: "Analyze this screen region and explain what you see. If there's text, code, or a UI element, help me understand or act on it.",
                    apiKey: miraState.effectiveAPIKey
                )
            }
        }
    }
}

// MARK: - Step row

private struct StepRow: View {
    let step: CUAStep

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 10))
                    .foregroundColor(iconColor)
                    .frame(width: 14)
                Text(step.details)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            if let ss = step.screenshot {
                Image(nsImage: ss)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 160)
                    .cornerRadius(6)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch step.action {
        case "screenshot":                  return "camera.fill"
        case "left_click", "double_click":  return "cursorarrow.click"
        case "right_click":                 return "cursorarrow.click.2"
        case "type":                        return "keyboard"
        case "key":                         return "keyboard.badge.ellipsis"
        case "scroll":                      return "scroll"
        case "mouse_move":                  return "cursorarrow.motionlines"
        case "left_click_drag":             return "cursorarrow.and.square.on.square.dashed"
        case "wait":                        return "clock"
        default:                            return "circle"
        }
    }

    private var iconColor: Color {
        switch step.action {
        case "screenshot": return .blue
        case "type", "key": return .orange
        default: return .secondary
        }
    }
}
