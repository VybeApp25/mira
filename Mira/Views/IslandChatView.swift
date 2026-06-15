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
    @State private var hasPlayedReceiveChime: Bool               = false   // one-time per response
    @State private var autoDismissWork:       DispatchWorkItem?  = nil

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

    private let accent    = DS.Colors.accent
    private let miraTeale = Color(red: 0.20, green: 0.85, blue: 0.75)
    private let surface   = DS.Colors.surface2
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
            bottomPanel
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
            autoDismissWork?.cancel()
            autoDismissWork = nil
            AudioCueService.shared.playTextClose()
            if !realtime.isAlwaysOnActive { realtime.stop() }
            miraState.realtimeState = .idle
        }
        .onChange(of: realtime.state) { _, newState in
            miraState.realtimeState = newState
            switch newState {
            case .idle:
                streamingMsgId = nil
            case .connecting:
                autoDismissWork?.cancel()
                autoDismissWork = nil
                hasPlayedReceiveChime = false
                wakeWord.pause()
                AudioCueService.shared.playVoiceStart()
            case .speaking:
                autoDismissWork?.cancel()
                autoDismissWork = nil
                if streamingMsgId == nil {
                    var msg = ChatMessage(role: .mira, text: "")
                    streamingMsgId = msg.id
                    messages.append(msg)
                }
                // One-time receive chime per response — matches HeyClicky's
                // hasPlayedTextReceiveChimeForCurrentResponse guard
                if !hasPlayedReceiveChime {
                    hasPlayedReceiveChime = true
                    AudioCueService.shared.playTextReceive()
                }
            case .recording:
                autoDismissWork?.cancel()
                autoDismissWork = nil
            default:
                break
            }
        }
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
            AudioCueService.shared.playTextOpen()
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
            .onChange(of: messages.count) {
                withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: isLoading) { _, loading in
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
            .background(DS.Colors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Message row

    @ViewBuilder
    private func messageRow(_ msg: ChatMessage) -> some View {
        if msg.role == .user {
            HStack {
                Spacer(minLength: 60)
                Text(msg.text)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.80))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(DS.Colors.surface3)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.extraLarge, style: .continuous))
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

    // MARK: - Bottom panel: NotchActivitySurface + hint row + InlineFollowUpComposer

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            if isVoiceActive {
                notchActivitySurface
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 0.5)
            voiceShortcutHintRow
            inlineFollowUpComposer
        }
        .background(DS.Colors.surface1)
        .animation(.easeInOut(duration: 0.18), value: isVoiceActive)
    }

    // Activity surface shown above the composer when voice is active
    private var notchActivitySurface: some View {
        HStack(spacing: 10) {
            VoiceActivityIndicator(state: realtime.state, powerHistory: realtime.audioPowerHistory)
                .frame(width: 44, height: 22)

            Text(voiceStatusLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.80))
                .animation(.easeInOut(duration: 0.15), value: voiceStatusLabel)

            Spacer()

            Button { realtime.stop() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundColor(.white.opacity(0.30))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // Single composer that morphs: waveform when recording, text field when idle
    private var inlineFollowUpComposer: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .fill(DS.Colors.surface2)

                if isVoiceActive {
                    HStack {
                        Spacer()
                        VoiceActivityIndicator(state: realtime.state, powerHistory: realtime.audioPowerHistory)
                            .frame(width: 64, height: 22)
                        Spacer()
                    }
                    .transition(.opacity)
                } else {
                    HStack(spacing: 0) {
                        ZStack(alignment: .leading) {
                            if input.isEmpty {
                                Text("Type a follow-up message")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.22))
                                    .accessibilityHidden(true)
                            }
                            TextField("", text: $input)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .tint(accent)
                                .onSubmit { Task { await submit() } }
                                .accessibilityLabel("Message")
                        }
                        if input.isEmpty {
                            wakeWordBadge.padding(.trailing, 4)
                        }
                    }
                    .padding(.horizontal, 12)
                    .transition(.opacity)
                }
            }
            .frame(height: 34)
            .animation(.easeInOut(duration: 0.18), value: isVoiceActive)
            .clipped()

            #if DEBUG
            if !isVoiceActive {
                inputIconButton(icon: "viewfinder.circle", a11yLabel: "Test overlay") { overlay.showTest() }
            }
            #endif

            if !isVoiceActive {
                inputIconButton(icon: "arrow.up.circle.fill",
                                tint: canSend ? accent : nil,
                                disabled: !canSend,
                                a11yLabel: "Send message") {
                    Task { await submit() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 9)
        .padding(.top, 4)
    }

    private var voiceShortcutHintRow: some View {
        let voiceLabel = ShortcutStore.shared.voice.displayString
        let alwaysOn   = realtime.isAlwaysOnActive
        return HStack(spacing: 6) {
            KeyCapChip(label: voiceLabel)
            Text("Hold to start a voice session. Release to send.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.22))
                .lineLimit(1)
            Spacer()
            Button {
                NotificationCenter.default.post(name: .miraToggleAlwaysOn, object: nil)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: alwaysOn ? "infinity.circle.fill" : "infinity.circle")
                        .font(.system(size: 12))
                        .foregroundColor(alwaysOn ? accent : .white.opacity(0.22))
                    if alwaysOn {
                        Text("Always on")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(accent)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 5)
        .padding(.bottom, 2)
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
        case .connecting:    return "Connecting..."
        case .recording:     return "Listening"
        case .transcribing:  return "Connecting..."
        case .thinking:      return realtime.toolStatus.isEmpty ? "Thinking" : "Thinking deeper"
        case .speaking:      return "Speaking"
        case .error(let m):  return m
        default:             return "Listening"
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
        autoDismissWork?.cancel()
        autoDismissWork = nil
        hasPlayedReceiveChime = false
        guard !realtime.isAlwaysOnActive else { return }
        guard case .idle = realtime.state else { return }
        realtime.connect(openAIKey: AppSecrets.openAIKey)
    }

    private func scheduleAutoDismiss(after delay: TimeInterval) {
        autoDismissWork?.cancel()
        let work = DispatchWorkItem {
            NotificationCenter.default.post(name: .miraRequestCollapse, object: nil)
        }
        autoDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Actions

    @MainActor
    private func submit() async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isLoading else { return }

        guard miraState.canUse else {
            errorText = !miraState.isSignedIn
                ? MiraError.notSignedIn.localizedDescription
                : MiraError.limitReached.localizedDescription
            return
        }

        input                 = ""
        errorText             = nil
        pendingAction         = nil
        pendingPermission     = nil
        hasPlayedReceiveChime = false
        autoDismissWork?.cancel(); autoDismissWork = nil
        messages.append(ChatMessage(role: .user, text: prompt))
        // Persist — the view is destroyed on island collapse, so anything not
        // in ConversationStore is gone the next time the island expands.
        ConversationStore.shared.save(role: "user", text: prompt)
        AudioCueService.shared.playTextSend()
        isLoading         = true

        // Classify via Haiku gate — async, falls back to sync keyword router if key missing.
        let context  = RouterContext(recentMessageCount: messages.count)
        let decision = await RouterService.shared.classifyIntent(
            prompt:  prompt,
            context: context,
            apiKey:  miraState.effectiveAPIKey
        )

        if decision.route == .websiteBuilder && miraState.isSignedIn {
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

        // Pre-append a streaming placeholder for routes that call Claude for text.
        // Clarification / confirmation / permission routes resolve without a Claude text reply.
        let skipStream: Set<MiraRoute> = [.clarificationRequired, .confirmationRequired, .permissionRequired]
        var placeholderID: UUID? = nil
        if !skipStream.contains(decision.route) {
            let ph = ChatMessage(role: .mira, text: "")
            streamingMsgId = ph.id
            placeholderID  = ph.id
            messages.append(ph)
        }

        // Extract callback with explicit type so the compiler can check the closure independently.
        var onStreamChunk: (@MainActor @Sendable (String) -> Void)? = nil
        if placeholderID != nil {
            onStreamChunk = { [self] chunk in
                if let idx = self.messages.firstIndex(where: { $0.id == self.streamingMsgId }) {
                    self.messages[idx].text = chunk
                }
            }
        }

        let result = await RouterService.shared.handle(
            prompt:        prompt,
            context:       context,
            apiKey:        miraState.effectiveAPIKey,
            capture:       capture,
            precomputed:   decision,
            onStreamChunk: onStreamChunk
        )
        streamingMsgId = nil

        switch result.route {
        case .clarificationRequired:
            if let id = placeholderID, let idx = messages.firstIndex(where: { $0.id == id }) {
                messages.remove(at: idx)
            }
            if let spec = result.clarificationSpec {
                if let opening = result.reply {
                    messages.append(ChatMessage(role: .mira, text: opening))
                }
                pendingClarification = spec
            } else if let q = result.clarificationQuestion {
                messages.append(ChatMessage(role: .mira, text: q))
            }
        case .confirmationRequired:
            if let id = placeholderID, let idx = messages.firstIndex(where: { $0.id == id }) {
                messages.remove(at: idx)
            }
            pendingAction = result.pendingConfirmation
        case .permissionRequired:
            if let id = placeholderID, let idx = messages.firstIndex(where: { $0.id == id }) {
                messages.remove(at: idx)
            }
            if let perm = result.missingPermission {
                retryPrompt       = prompt
                pendingPermission = perm
            } else {
                errorText = result.permissionNeeded
            }
        default:
            if let reply = result.reply {
                // If streaming filled the placeholder, leave it; otherwise fill it now.
                if let id = placeholderID, let idx = messages.firstIndex(where: { $0.id == id }) {
                    if messages[idx].text.isEmpty { messages[idx].text = reply }
                } else {
                    messages.append(ChatMessage(role: .mira, text: reply))
                }
                ConversationStore.shared.save(role: "mira", text: reply)
                if !hasPlayedReceiveChime {
                    hasPlayedReceiveChime = true
                    AudioCueService.shared.playTextReceive()
                }
                if reply.count < 280 {
                    CursorCompanionManager.shared.send(.chatReply(reply))
                }
                if let info = detectArtifact(in: reply) {
                    messages.append(ChatMessage(role: .mira, widget: .artifact(info)))
                }
                scheduleAutoDismiss(after: 8.0)
            }
            else if let id = placeholderID,
                    let idx = messages.firstIndex(where: { $0.id == id }),
                    messages[idx].text.isEmpty {
                // No text reply for this route — drop the unused placeholder
                // so an empty bubble doesn't linger in the thread.
                messages.remove(at: idx)
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
            let reply = try await AgentService.shared.confirm(action: action)
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

    private let accent  = DS.Colors.accent
    private let green   = DS.Colors.success
    private let red     = DS.Colors.error
    private let surface = DS.Colors.surface1

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
                            DS.Colors.surface3.frame(height: 2)
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
                                object: IslandTab.agents
                            )
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "cpu")
                                    .font(.system(size: 9))
                                Text("View in Agents")
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
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.large).stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
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

// MARK: - Color lerp helper

private func lerp(_ a: Color, _ b: Color, t: CGFloat) -> Color {
    guard let ca = NSColor(a).usingColorSpace(.sRGB),
          let cb = NSColor(b).usingColorSpace(.sRGB) else { return a }
    return Color(
        red:   ca.redComponent   + (cb.redComponent   - ca.redComponent)   * t,
        green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
        blue:  ca.blueComponent  + (cb.blueComponent  - ca.blueComponent)  * t
    )
}

// MARK: - Realtime orb

/// Animated circle that reflects the current realtime voice state.
// HeyClicky-style three-state voice activity indicator:
// recording → waveform bars driven by mic power
// thinking  → three bouncing dots
// speaking  → equalizer bars at staggered speeds
private struct VoiceActivityIndicator: View {
    let state: RealtimeState
    let powerHistory: [CGFloat]

    var body: some View {
        switch state {
        case .recording:
            ListeningWaveformBars(powerHistory: powerHistory)
        case .thinking, .connecting, .transcribing:
            ThinkingDots()
        case .speaking:
            SpeakingEqualizerBars()
        default:
            ListeningWaveformBars(powerHistory: Array(repeating: 0.02, count: 44))
        }
    }
}

private struct ListeningWaveformBars: View {
    let powerHistory: [CGFloat]

    private let barCount = 7
    private let barWidth: CGFloat = 3
    private let spacing:  CGFloat = 2.5

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { i in
                let idx = max(0, powerHistory.count - barCount + i)
                let raw  = idx < powerHistory.count ? powerHistory[idx] : 0.02
                let h    = max(3, raw * 26)
                let t = CGFloat(i) / CGFloat(barCount - 1)
                let barColor = lerp(BuddyComposerVisualStyle.waveformLeadingColor,
                                    BuddyComposerVisualStyle.waveformTrailingColor, t: t)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor)
                    .frame(width: barWidth, height: h)
                    .shadow(color: BuddyComposerVisualStyle.waveformGlowColor.opacity(0.5), radius: 3)
                    .animation(.easeOut(duration: 0.08), value: h)
            }
        }
    }
}

private struct ThinkingDots: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color(red: 0.98, green: 0.82, blue: 0.34))
                    .frame(width: 6, height: 6)
                    .offset(y: sin(phase + CGFloat(i) * .pi * 0.7) * 5)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}

private struct SpeakingEqualizerBars: View {
    private let barCount = 5
    private let barWidth: CGFloat = 3.5
    private let spacing:  CGFloat = 2.5
    private let speeds:   [Double] = [0.38, 0.52, 0.31, 0.58, 0.44]
    @State private var heights: [CGFloat] = [10, 18, 8, 22, 14]

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(BuddyComposerVisualStyle.waveformTrailingColor)
                    .frame(width: barWidth, height: heights[i])
                    .animation(
                        .easeInOut(duration: speeds[i]).repeatForever(autoreverses: true),
                        value: heights[i]
                    )
            }
        }
        .onAppear {
            for i in 0..<barCount {
                withAnimation(
                    .easeInOut(duration: speeds[i]).repeatForever(autoreverses: true)
                ) {
                    heights[i] = [24, 10, 26, 8, 20][i]
                }
            }
        }
    }
}

// MARK: - KeyCap chip (HeyClicky-style shortcut hint)

private struct KeyCapChip: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.45))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
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
