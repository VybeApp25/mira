import SwiftUI

// MARK: - Message model

struct ChatMessage: Identifiable {
    let id          = UUID()
    let role:        Role
    var text:        String
    var agentJobId:  UUID?        // non-nil → renders InlineChatJobCard instead of text bubble
    var widget:      ChatWidget?  // non-nil → renders ChatWidgetCardView
    let timestamp:   Date = .now
    enum Role { case user, mira }

    init(role: Role, text: String) {
        self.role = role; self.text = text; self.agentJobId = nil; self.widget = nil
    }
    init(role: Role, jobId: UUID) {
        self.role = role; self.text = ""; self.agentJobId = jobId; self.widget = nil
    }
    init(role: Role, widget: ChatWidget) {
        self.role = role; self.text = ""; self.agentJobId = nil; self.widget = widget
    }
}

// Scans a Mira reply for absolute file paths and returns ArtifactInfo if a file is found.
private func detectArtifact(in text: String) -> ArtifactInfo? {
    let pattern = #"(/(?:Users|tmp|private/tmp|var/folders)[^\s'"`,\)]+\.[a-zA-Z0-9]{1,8})"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          let r = Range(match.range(at: 1), in: text) else { return nil }
    let rawPath = String(text[r]).replacingOccurrences(of: "~", with: NSHomeDirectory())
    let url = URL(fileURLWithPath: rawPath)
    guard FileManager.default.fileExists(atPath: url.path),
          !FileManager.default.isDirectory(url) else { return nil }
    let attrs  = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size   = (attrs?[.size] as? Int64) ?? 0
    let ext    = url.pathExtension.lowercased()
    let name   = url.lastPathComponent
    return ArtifactInfo(url: url, name: name, ext: ext, sizeBytes: size)
}

private extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - Chat view

struct IslandChatView: View {
    @ObservedObject var miraState: MiraState
    @ObservedObject var overlay:   OverlayWindowController
    let capture: ScreenCaptureService
    @ObservedObject var voice:     VoiceService
    @ObservedObject var wakeWord:  WakeWordService

    @State private var messages:        [ChatMessage] = []
    @State private var input:                 String             = ""
    @State private var isLoading:             Bool               = false
    @State private var pendingAction:         PendingAction?     = nil
    @State private var pendingClarification:  ClarificationSpec? = nil
    @State private var pendingPermission:     MiraPermission?    = nil
    @State private var retryPrompt:           String?            = nil
    @State private var errorText:             String?            = nil
    @State private var streamingMsgId:        UUID?              = nil
    @State private var isCodeMode:            Bool               = false   // Claude Code bridge

    // Use the app-lifetime singleton — mirrors HeyClicky's always-on architecture.
    // @ObservedObject (not @StateObject) because the session outlives this view.
    @ObservedObject private var realtime = RealtimeVoiceService.shared
    @ObservedObject private var tts = MisoTTSService.shared
    @State private var speakingMessageID: UUID? = nil
    @ObservedObject private var dictate = AssemblyAIStreamingService.shared
    private var isVoiceActive: Bool {
        switch realtime.state {
        case .idle: return false
        default:    return true
        }
    }

    private let accent    = Color(red: 0.29, green: 0.62, blue: 1.0)
    private let miraTeale = Color(red: 0.20, green: 0.85, blue: 0.75)
    private let surface   = Color(red: 0.14, green: 0.14, blue: 0.17)
    private var claude: ClaudeService { ClaudeService(apiKey: miraState.effectiveAPIKey) }

    var body: some View {
        VStack(spacing: 0) {
            messageArea
            ClarificationCard(spec: $pendingClarification) { assembled in
                input = assembled
                Task { await submit() }
            }
            if let perm = pendingPermission {
                PermissionRecoveryCard(permission: perm) {
                    // permission granted — auto-retry blocked request
                    pendingPermission = nil
                    if let prompt = retryPrompt {
                        retryPrompt = nil
                        input = prompt
                        Task { await submit() }
                    }
                } onDismiss: {
                    pendingPermission = nil
                    retryPrompt = nil
                }
            }
            if let action = pendingAction { confirmCard(action) }
            if let err    = errorText     { errorBanner(err)    }
            if isVoiceActive { voiceStatusBar } else { inputBar }
        }
        .onChange(of: dictate.partial) { _, partial in
            if dictate.isStreaming { input = partial }
        }
        .onChange(of: dictate.isStreaming) { _, streaming in
            if !streaming { input = dictate.fullTranscript }
        }
        .onAppear {
            wireRealtime()
            loadHistory()
            AudioCueService.shared.play(.enter)
        }
        .onDisappear {
            AudioCueService.shared.playTextClose()
            // Keep always-on session alive when island closes — HeyClicky never stops
            // the session just because the notch UI is hidden.
            if !realtime.isAlwaysOnActive { realtime.stop() }
            miraState.realtimeState = .idle
        }
        // Pause wake word while realtime session is live; NotchManager restarts it on collapse.
        // Also mirror state into MiraState so the collapsed pill can show thinking/speaking.
        .onChange(of: realtime.state) { _, newState in
            miraState.realtimeState = newState
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
        // .miraVoiceChanged no longer used — GA API removed voice as a session parameter
        // Fix 3: chip tap from the HUD overlay routes here
        .onReceive(NotificationCenter.default.publisher(for: .miraChipPromptSelected)) { note in
            guard let prompt = note.userInfo?["prompt"] as? String else { return }
            input = prompt
            Task { await submit() }
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
                // Mirror to miraState so FloatingButtonService and PillStateModel see the loading state.
                miraState.isLoading = loading
            }
        }
    }

    // MARK: - Placeholder (NotchUseCaseCarousel port from HeyClicky)
    // Shows contextual use-case chips so the empty state actively prompts engagement.

    private static let suggestions: [(icon: String, label: String)] = [
        ("calendar",           "What's on my calendar?"),
        ("envelope",           "Draft an email"),
        ("magnifyingglass",    "Search the web"),
        ("sparkle",            "Plan my day"),
        ("doc.text",           "Review my code"),
        ("music.note",         "What's playing?"),
    ]

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What can I help with?")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.18))
                .padding(.top, 4)

            // 2-column grid of suggestion chips
            let cols = [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)]
            LazyVGrid(columns: cols, spacing: 7) {
                ForEach(Self.suggestions, id: \.label) { s in
                    suggestionChip(icon: s.icon, s.label)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
    }

    private func suggestionChip(icon: String, _ label: String) -> some View {
        Button {
            input = label
            Task { await submit() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(accent.opacity(0.75))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.60))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
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
        } else if let jobId = msg.agentJobId {
            // Agent job card — live status inline in chat
            InlineChatJobCard(jobId: jobId)
        } else if let widget = msg.widget {
            // Structured data widget card (stock, images, place)
            ChatWidgetCardView(widget: widget)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Mira: rendered markdown + optional ElevenLabs speak button
            HStack(alignment: .top, spacing: 6) {
                StreamingMarkdownView(text: msg.text, fontSize: 13)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if tts.isConfigured && !msg.text.isEmpty {
                    Button {
                        if speakingMessageID == msg.id {
                            tts.stop()
                            speakingMessageID = nil
                        } else {
                            speakingMessageID = msg.id
                            tts.speak(msg.text)
                        }
                    } label: {
                        Image(systemName: speakingMessageID == msg.id ? "stop.circle.fill" : "speaker.wave.2")
                            .font(.system(size: 10))
                            .foregroundColor(speakingMessageID == msg.id ? miraTeale : .white.opacity(0.20))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onChange(of: tts.isSpeaking) { _, speaking in
                if !speaking { speakingMessageID = nil }
            }
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
                    .accessibilityHidden(true)
                }
                TextField("", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .tint(accent)
                    .padding(.horizontal, 12)
                    .onSubmit { Task { await submit() } }
                    .accessibilityLabel("Message to Mira")
            }
            .frame(height: 34)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Realtime voice mic button — activates GPT-4o Realtime
            inputIconButton(
                icon: realtime.state == .idle ? "waveform.circle" : "waveform.circle.fill",
                tint: realtime.state == .idle ? nil : .red,
                a11yLabel: realtime.state == .idle ? "Start voice session" : "End voice session"
            ) { toggleRealtime() }

            // AssemblyAI dictate — streams mic to AssemblyAI; populates text field live
            inputIconButton(
                icon: dictate.isStreaming ? "mic.circle.fill" : "mic.circle",
                tint: dictate.isStreaming ? .orange : nil,
                a11yLabel: dictate.isStreaming ? "Stop dictating" : "Dictate with AssemblyAI"
            ) { toggleDictate() }

            // Claude Code toggle — routes submission through ClaudeCodeBridge
            if ClaudeCodeBridge.shared.isAvailable {
                inputIconButton(
                    icon: "chevron.left.forwardslash.chevron.right",
                    tint: isCodeMode ? miraTeale : nil,
                    a11yLabel: isCodeMode ? "Switch to chat mode" : "Switch to code mode"
                ) {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
                        isCodeMode.toggle()
                    }
                }
            }

            #if DEBUG
            inputIconButton(icon: "viewfinder.circle", a11yLabel: "Test overlay") { overlay.showTest() }
            #endif

            inputIconButton(icon: "arrow.up.circle.fill",
                            tint: canSend ? accent : nil,
                            disabled: !canSend,
                            a11yLabel: "Send message") {
                if isCodeMode {
                    Task { await submitWithCode() }
                } else {
                    Task { await submit() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.03))
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(.white.opacity(0.07)), alignment: .top)
    }

    private func inputIconButton(icon: String, tint: Color? = nil, disabled: Bool = false,
                                  a11yLabel: String = "", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor((tint ?? .white).opacity(disabled ? 0.15 : (tint == nil ? 0.30 : 1.0)))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(a11yLabel.isEmpty ? icon : a11yLabel)
    }

    private var canSend: Bool { !input.trimmingCharacters(in: .whitespaces).isEmpty && !isLoading }

    // MARK: - AssemblyAI dictation

    private func toggleDictate() {
        if dictate.isStreaming {
            dictate.stopStreaming()
            // fullTranscript is already reflected via onChange below
        } else {
            try? dictate.startStreaming()
        }
    }

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
        // Always-on: session already running — nothing to do.
        guard !realtime.isAlwaysOnActive else { return }
        // Fallback for non-always-on launch
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

        input             = ""
        errorText         = nil
        pendingAction     = nil
        pendingPermission = nil
        messages.append(ChatMessage(role: .user, text: prompt))
        AudioCueService.shared.playTextSend()
        isLoading         = true

        // Classify via Haiku gate — async, falls back to sync keyword router if key missing.
        let context  = RouterContext(recentMessageCount: messages.count)
        let decision = await RouterService.shared.classifyIntent(
            prompt:  prompt,
            context: context,
            apiKey:  miraState.effectiveAPIKey
        )

        if decision.route == .websiteBuilder && !miraState.effectiveAPIKey.isEmpty {
            // Launch inline agent job — shows live status card in chat thread
            let job = AgentJobStore.shared.submitJob(
                prompt: prompt,
                apiKey: miraState.effectiveAPIKey,
                buildMode: .pro
            )
            messages.append(ChatMessage(role: .mira, jobId: job.id))
            miraState.recordUsage()
            isLoading = false
            return
        }

        if decision.route == .clarificationRequired,
           let spec = decision.clarificationSpec, spec.intent == .websiteBuilder {
            messages.append(ChatMessage(role: .mira, text: spec.opening))
            pendingClarification = spec
            isLoading = false
            return
        }

        // Widget routes — fetch structured data; fall through to handle() on failure.
        if [MiraRoute.stockLookup, .imageSearch, .placeSearch].contains(decision.route) {
            let widget = await fetchWidget(route: decision.route, prompt: prompt)
            if let widget {
                messages.append(ChatMessage(role: .mira, widget: widget))
                miraState.recordUsage()
                isLoading = false
                return
            }
            // Data fetch failed — handle() will call Claude for a text answer
        }

        let result = await RouterService.shared.handle(
            prompt:      prompt,
            context:     context,
            apiKey:      miraState.effectiveAPIKey,
            capture:     capture,
            precomputed: decision
        )

        switch result.route {
        case .clarificationRequired:
            if let spec = result.clarificationSpec {
                if let opening = result.reply {
                    messages.append(ChatMessage(role: .mira, text: opening))
                }
                pendingClarification = spec
            } else if let q = result.clarificationQuestion {
                messages.append(ChatMessage(role: .mira, text: q))
            }
        case .confirmationRequired:
            pendingAction = result.pendingConfirmation
        case .permissionRequired:
            if let perm = result.missingPermission {
                retryPrompt       = prompt
                pendingPermission = perm
            } else {
                errorText = result.permissionNeeded
            }
        default:
            if let reply = result.reply {
                messages.append(ChatMessage(role: .mira, text: reply))
                AudioCueService.shared.playTextReceive()
                // Surface compact replies in the cursor companion so the island
                // doesn't need to stay open for short conversational responses.
                if reply.count < 280 {
                    CursorCompanionManager.shared.send(.chatReply(reply))
                }
                // Detect file artifacts in the reply and append a preview card.
                if let info = detectArtifact(in: reply) {
                    messages.append(ChatMessage(role: .mira, widget: .artifact(info)))
                }
            }
            if let target = result.guidanceTarget, target.confidence >= 0.60 {
                overlay.showGuidance(GuidanceFrame(timestamp: .now, targets: [target]))
            }
            miraState.recordUsage()
        }

        isLoading = false
    }

    @MainActor
    private func fetchWidget(route: MiraRoute, prompt: String) async -> ChatWidget? {
        switch route {
        case .stockLookup:
            if let q = await ChatWidgetService.shared.fetchStock(query: prompt) { return .stock(q) }
        case .imageSearch:
            let imgs = await ChatWidgetService.shared.fetchImages(query: prompt)
            if !imgs.isEmpty { return .images(imgs) }
        case .placeSearch:
            if let p = await ChatWidgetService.shared.fetchPlace(query: prompt) { return .place(p) }
        default:
            break
        }
        return nil
    }

    @MainActor
    private func confirm(_ action: PendingAction) async {
        pendingAction = nil
        isLoading     = true
        do {
            let reply = try await AgentService.shared.confirm(action: action, claudeApiKey: miraState.effectiveAPIKey)
            messages.append(ChatMessage(role: .mira, text: reply))
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

    // MARK: - Claude Code Bridge submission

    @MainActor
    private func submitWithCode() async {
        let prompt = input.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return }

        input     = ""
        isLoading = true
        miraState.isLoading = true

        // User message bubble
        messages.append(ChatMessage(role: .user, text: prompt))
        ConversationStore.shared.save(role: "user", text: prompt)

        // Streaming Mira response placeholder
        var miraMsg = ChatMessage(role: .mira, text: "")
        messages.append(miraMsg)
        let miraMsgId = miraMsg.id
        streamingMsgId = miraMsgId

        // Start cursor bubble for collapsed-pill streaming
        CursorBubbleService.shared.showStreaming()

        do {
            let result = try await ClaudeCodeBridge.shared.run(
                prompt: prompt,
                onToken: { chunk in
                    // Append streaming text to the last Mira message
                    if let idx = self.messages.firstIndex(where: { $0.id == miraMsgId }) {
                        self.messages[idx].text += chunk
                    }
                    CursorBubbleService.shared.append(token: chunk)
                },
                onArtifact: { artifact in
                    ResponseCardService.shared.append(artifact: artifact)
                }
            )

            // Finalise
            if let idx = messages.firstIndex(where: { $0.id == miraMsgId }) {
                if messages[idx].text.isEmpty { messages[idx].text = result.text }
            }
            ConversationStore.shared.save(role: "mira", text: result.text)

            if result.costUSD > 0 {
                let costNote = String(format: "  *(Claude Code · $%.4f)*", result.costUSD)
                if let idx = messages.firstIndex(where: { $0.id == miraMsgId }) {
                    messages[idx].text += costNote
                }
            }
        } catch {
            if let idx = messages.firstIndex(where: { $0.id == miraMsgId }) {
                messages[idx].text = "*Claude Code error: \(error.localizedDescription)*"
            }
        }

        streamingMsgId = nil
        isLoading = false
        miraState.isLoading = false
        CursorBubbleService.shared.finishStreaming()
    }
}

// MARK: - Inline Chat Job Card

/// Live agent job status card rendered inside the chat thread.
/// Observes AgentJobStore so it self-updates without any polling.

/// Live agent job status card rendered inside the chat thread.
/// Observes AgentJobStore so it self-updates without any polling.
private struct InlineChatJobCard: View {
    let jobId: UUID
    @StateObject private var store = AgentJobStore.shared

    private var job: AgentJob? { store.job(id: jobId) }

    private let accent  = Color(red: 0.29, green: 0.62, blue: 1.0)
    private let green   = Color(red: 0.20, green: 0.84, blue: 0.29)
    private let red     = Color(red: 1.0,  green: 0.35, blue: 0.35)
    private let surface = Color(red: 0.13, green: 0.13, blue: 0.16)

    var body: some View {
        if let job = job {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(statusColor(job.status).opacity(0.14))
                            .frame(width: 22, height: 22)
                        Image(systemName: job.type.icon)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(statusColor(job.status))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.status.isTerminal ? job.status.displayName : job.currentStep)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        Text(job.prompt)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.30))
                            .lineLimit(1)
                    }
                    Spacer()
                    if job.status.isActive {
                        Text("\(Int(job.progress * 100))%")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(green.opacity(0.80))
                    }
                }
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)

                // Progress bar (running only)
                if job.status.isActive {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Color.white.opacity(0.06).frame(height: 2)
                            green
                                .frame(width: max(0, geo.size.width * job.progress), height: 2)
                                .animation(.linear(duration: 0.4), value: job.progress)
                        }
                    }
                    .frame(height: 2)
                    .padding(.bottom, 8)
                }

                // Completion actions
                if job.status == .completed {
                    HStack(spacing: 6) {
                        if let previewPath = job.result?.previewImagePath,
                           let img = NSImage(contentsOfFile: previewPath) {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 52, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        Button {
                            NotificationCenter.default.post(
                                name: .miraTabSelected,
                                object: IslandTab.projects
                            )
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.system(size: 9))
                                Text("View in Library")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(accent)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(accent.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.bottom, 10)
                } else if job.status == .failed {
                    Text(job.errorMessage ?? "Build failed")
                        .font(.system(size: 10))
                        .foregroundColor(red.opacity(0.80))
                        .padding(.horizontal, 10).padding(.bottom, 8)
                } else if !job.status.isActive {
                    Color.clear.frame(height: 4)
                }
            }
            .background(surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusColor(_ status: AgentJobStatus) -> Color {
        switch status {
        case .completed:  return green
        case .failed:     return red
        case .cancelled:  return .white.opacity(0.30)
        default:          return accent
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
