import SwiftUI

// MARK: - Message model

struct ChatMessage: Identifiable {
    let id        = UUID()
    let role:       Role
    var text:       String
    let timestamp:  Date = .now
    enum Role { case user, mira }
}

// MARK: - Chat view

struct IslandChatView: View {
    @ObservedObject var miraState: MiraState
    @ObservedObject var overlay:   OverlayWindowController
    let capture: ScreenCaptureService
    @ObservedObject var voice:     VoiceService
    @ObservedObject var wakeWord:  WakeWordService

    @State private var messages:        [ChatMessage] = []
    @State private var input:           String        = ""
    @State private var isLoading:       Bool          = false
    @State private var pendingAction:   PendingAction? = nil
    @State private var errorText:       String?       = nil
    @State private var agentOnline:     Bool          = false
    @State private var streamingMsgId:  UUID?         = nil

    @StateObject private var realtime = RealtimeVoiceService()
    private var isVoiceActive: Bool {
        switch realtime.state {
        case .idle: return false
        default:    return true
        }
    }

    private let accent  = Color(red: 0.29, green: 0.62, blue: 1.0)
    private let surface = Color(red: 0.14, green: 0.14, blue: 0.17)
    private var claude: ClaudeService { ClaudeService(apiKey: miraState.effectiveAPIKey) }

    var body: some View {
        VStack(spacing: 0) {
            messageArea
            if let action = pendingAction { confirmCard(action) }
            if let err    = errorText     { errorBanner(err)    }
            if isVoiceActive { voiceStatusBar } else { inputBar }
        }
        .task { agentOnline = await AgentService.shared.checkHealth() }
        .onAppear {
            wireRealtime()
            loadHistory()
        }
        .onDisappear {
            realtime.stop()
        }
        // Pause wake word while realtime session is live; NotchManager restarts it on collapse.
        .onChange(of: realtime.state) { _, newState in
            switch newState {
            case .idle:
                break
            case .connecting:
                wakeWord.pause()
            case .speaking:
                // Add streaming placeholder when AI starts speaking
                if streamingMsgId == nil {
                    var msg = ChatMessage(role: .mira, text: "")
                    streamingMsgId = msg.id
                    messages.append(msg)
                }
            default:
                break
            }
        }
        // Live-update the streaming message as AI transcript chunks arrive
        .onChange(of: realtime.aiDraft) { _, draft in
            guard !draft.isEmpty,
                  let id  = streamingMsgId,
                  let idx = messages.firstIndex(where: { $0.id == id }) else { return }
            messages[idx].text = draft
        }
        .onReceive(NotificationCenter.default.publisher(for: .miraActivateVoice)) { _ in
            startVoice()
        }
        .onReceive(NotificationCenter.default.publisher(for: .miraActivateText)) { _ in
            // Text mode — text field gets focus on next click
        }
        .onReceive(NotificationCenter.default.publisher(for: .miraVoiceChanged)) { _ in
            realtime.updateVoice()
        }
    }

    // Wire realtime callbacks once on appear
    private func wireRealtime() {
        realtime.onUserMessage = { text in
            messages.append(ChatMessage(role: .user, text: text))
            ConversationStore.shared.save(role: "user", text: text)
        }
        realtime.onAIMessage = { text in
            // Finalise the streaming placeholder if present; otherwise append new message
            if let id  = streamingMsgId,
               let idx = messages.firstIndex(where: { $0.id == id }) {
                messages[idx].text = text
            } else {
                messages.append(ChatMessage(role: .mira, text: text))
            }
            streamingMsgId = nil
            ConversationStore.shared.save(role: "mira", text: text)
        }
    }

    // Load persisted history into the message list on first appear
    private func loadHistory() {
        guard messages.isEmpty else { return }
        let history = ConversationStore.shared.entries.suffix(30)
        messages = history.map { e in
            ChatMessage(role: e.role == "user" ? .user : .mira, text: e.text)
        }
    }

    // MARK: - Message area

    private var messageArea: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty && !isLoading {
                        placeholder
                    }
                    ForEach(messages) { msg in
                        messageRow(msg).id(msg.id)
                    }
                    if isLoading {
                        typingRow.id("typing")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: messages.count) { _ in
                withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: isLoading) { loading in
                if loading { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
            }
        }
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        VStack(spacing: 6) {
            Text("How can I help you today?")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.20))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 20)
    }

    // MARK: - Message row

    @ViewBuilder
    private func messageRow(_ msg: ChatMessage) -> some View {
        if msg.role == .user {
            // User: right-aligned bubble
            HStack {
                Spacer(minLength: 80)
                Text(msg.text)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(accent.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            // Mira: plain text, no bubble — matches mockup Image #7
            Text(msg.text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.90))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Typing indicator

    private var typingRow: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in TypingDot(index: i) }
        }
    }

    // MARK: - Confirmation card

    private func confirmCard(_ action: PendingAction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundColor(.orange).font(.system(size: 12))
            Text("Ready to **\(action.description)**.")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
            Spacer()
            Button("Confirm") { Task { await confirm(action) } }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accent)
                .buttonStyle(.plain)
            Button("Cancel") { pendingAction = nil }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.40))
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(.orange.opacity(0.25)), alignment: .top)
    }

    // MARK: - Error banner

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange).font(.system(size: 10))
            Text(msg).font(.system(size: 11)).foregroundColor(.white.opacity(0.70))
            Spacer()
            Button { errorText = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(.white.opacity(0.35))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Color.orange.opacity(0.09))
    }

    // MARK: - Input bar (matches mockup: wide field + 3 icon buttons)

    private var inputBar: some View {
        HStack(spacing: 8) {
            // Text field
            ZStack(alignment: .leading) {
                if input.isEmpty {
                    HStack(spacing: 0) {
                        Text("How can I help you today?")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.22))
                        Spacer()
                        wakeWordBadge.padding(.trailing, 4)
                    }
                    .padding(.horizontal, 12)
                }
                TextField("", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .tint(accent)
                    .padding(.horizontal, 12)
                    .onSubmit { Task { await submit() } }
            }
            .frame(height: 34)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Realtime voice mic button — activates GPT-4o Realtime
            inputIconButton(
                icon: realtime.state == .idle ? "waveform.circle" : "waveform.circle.fill",
                tint: realtime.state == .idle ? nil : .red
            ) { toggleRealtime() }

            inputIconButton(icon: "arrow.up.circle.fill",
                            tint: canSend ? accent : nil,
                            disabled: !canSend) {
                Task { await submit() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.03))
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(.white.opacity(0.07)), alignment: .top)
    }

    private func inputIconButton(icon: String, tint: Color? = nil, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor((tint ?? .white).opacity(disabled ? 0.15 : (tint == nil ? 0.30 : 1.0)))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var canSend: Bool { !input.trimmingCharacters(in: .whitespaces).isEmpty && !isLoading }

    // MARK: - Voice status bar (shown instead of input bar when realtime is active)

    private var voiceStatusBar: some View {
        HStack(spacing: 12) {
            RealtimeOrb(state: realtime.state)

            VStack(alignment: .leading, spacing: 2) {
                Text(voiceStatusLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)

                // Priority: tool status > user draft > ai transcript
                let subtitle: String = {
                    if !realtime.toolStatus.isEmpty  { return realtime.toolStatus }
                    if realtime.state == .recording   { return realtime.userDraft }
                    return realtime.aiDraft
                }()
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(realtime.toolStatus.isEmpty
                                         ? .white.opacity(0.45)
                                         : Color(red: 1.0, green: 0.70, blue: 0.25))
                        .lineLimit(1)
                        .animation(.easeInOut(duration: 0.2), value: subtitle)
                }
            }

            Spacer()

            Button { realtime.stop() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.04))
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(.white.opacity(0.07)), alignment: .top)
    }

    // Wake word idle indicator — shown in input bar when not in a voice session
    private var wakeWordBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(red: 0.20, green: 0.84, blue: 0.29).opacity(wakeWord.isListening ? 1.0 : 0))
                .frame(width: 5, height: 5)
            Text("Hey Mira")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(wakeWord.isListening ? 0.28 : 0))
        }
        .animation(.easeInOut(duration: 0.4), value: wakeWord.isListening)
    }

    private var voiceStatusLabel: String {
        switch realtime.state {
        case .connecting:    return "Connecting…"
        case .recording:     return "Listening…"
        case .transcribing:  return "Connecting…"
        case .thinking:      return "Thinking…"
        case .speaking:      return "Mira is speaking"
        case .error(let m):  return m
        default:             return "Voice"
        }
    }

    private func toggleRealtime() {
        switch realtime.state {
        case .idle, .error: startVoice()
        case .recording:    realtime.stop()    // manual cancel while recording
        default:            realtime.stop()
        }
    }

    private func startVoice() {
        guard case .idle = realtime.state else { return }
        realtime.connect(openAIKey: AppSecrets.openAIKey)
    }

    // MARK: - Actions

    @MainActor
    private func submit() async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isLoading else { return }

        guard miraState.canUse else {
            errorText = miraState.effectiveAPIKey.isEmpty
                ? MiraError.noKey.localizedDescription
                : MiraError.limitReached.localizedDescription
            return
        }

        input         = ""
        errorText     = nil
        pendingAction = nil
        messages.append(ChatMessage(role: .user, text: prompt))
        isLoading     = true

        do {
            if agentOnline {
                let result = try await AgentService.shared.run(prompt: prompt, claudeApiKey: miraState.effectiveAPIKey)
                if let pending = result.requiresConfirmation {
                    pendingAction = pending
                } else {
                    messages.append(ChatMessage(role: .mira, text: result.reply))
                    voice.speak(result.reply)
                }
            } else {
                let screenshot = try? await capture.captureMainDisplay()
                let text = try await claude.ask(prompt: prompt, screenshot: screenshot)
                messages.append(ChatMessage(role: .mira, text: text))
                voice.speak(text)
                if let img = screenshot, let pt = try? await claude.locateElement(prompt, in: img) {
                    overlay.show(at: pt, label: "Here")
                }
            }
            miraState.recordUsage()
        } catch {
            errorText = error.localizedDescription
        }

        isLoading = false
    }

    @MainActor
    private func confirm(_ action: PendingAction) async {
        pendingAction = nil
        isLoading     = true
        do {
            let reply = try await AgentService.shared.confirm(action: action, claudeApiKey: miraState.effectiveAPIKey)
            messages.append(ChatMessage(role: .mira, text: reply))
            voice.speak(reply)
        } catch { errorText = error.localizedDescription }
        isLoading = false
    }

    @MainActor
    private func toggleVoice() async {
        if voice.isListening {
            let text = voice.stopListening()
            if !text.isEmpty { input = text; await submit() }
        } else {
            await voice.requestPermissions()
            try? voice.startListening()
        }
    }
}

// MARK: - Realtime orb

/// Animated circle that reflects the current realtime voice state.
private struct RealtimeOrb: View {
    let state: RealtimeState
    @State private var pulse: CGFloat = 1.0

    private var color: Color {
        switch state {
        case .recording:    return Color(red: 0.20, green: 0.84, blue: 0.29)
        case .transcribing: return Color(red: 0.29, green: 0.62, blue: 1.0)
        case .thinking:     return Color(red: 1.0,  green: 0.75, blue: 0.20)
        case .speaking:     return Color(red: 0.75, green: 0.35, blue: 0.95)
        default:            return .white.opacity(0.25)
        }
    }

    private var shouldPulse: Bool {
        state == .recording || state == .speaking
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.20))
                .frame(width: 32, height: 32)
                .scaleEffect(pulse)
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
            Image(systemName: "waveform")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
        }
        .onChange(of: shouldPulse) { active in
            if active {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = 1.35
                }
            } else {
                withAnimation(.spring()) { pulse = 1.0 }
            }
        }
    }
}

// MARK: - Typing dot

private struct TypingDot: View {
    let index: Int
    @State private var scale: CGFloat = 0.5
    var body: some View {
        Circle()
            .fill(Color.white.opacity(0.40))
            .frame(width: 6, height: 6)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.50)
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.17)
                ) { scale = 1.0 }
            }
    }
}
