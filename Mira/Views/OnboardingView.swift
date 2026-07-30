import SwiftUI
import AppKit
import AVKit
import AVFoundation

// MARK: - Design tokens

private let bg      = Color(red: 0.07, green: 0.07, blue: 0.09)
private let surface = Color(red: 0.12, green: 0.12, blue: 0.15)
private let dim     = Color(red: 0.16, green: 0.16, blue: 0.20)
private let accent  = DS.Colors.accent

// MARK: - Onboarding step enum

enum OnboardingStep: Equatable, Hashable {
    case intro
    case signIn
    case voicePersona
    case knowledgeImport
    case discovery
    case permission(MiraPermission)
    case agentFolder
    case demoAgent
    case demoFindInteresting
    case demoIdentify
    case demoDraftReply
    case finale
    case paywall
    case done
}

// MARK: - Main view

struct OnboardingView: View {
    let onDismiss: () -> Void

    @StateObject private var svc      = OnboardingService.shared
    @ObservedObject private var acct  = AccountService.shared
    @ObservedObject private var narrator = OnboardingNarrator.shared

    @State private var step:        OnboardingStep = .intro
    @State private var steps:       [OnboardingStep] = []
    @State private var stepIndex:   Int = 0
    @State private var direction:   Int = 1  // +1 forward, -1 back

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            buildSteps()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center) {
            // Step progress strip (hidden on intro/done)
            if step != .intro && step != .done {
                progressStrip
            } else {
                Color.clear.frame(height: 4)
            }

            Spacer()

            // Speaking indicator
            if narrator.isSpeaking {
                NarratorWaveform()
                    .padding(.trailing, 8)
                    .transition(.opacity)
            }

            // Skip button (intro only) / close on done
            if step == .intro || step == .done {
                Button {
                    if step == .intro { advance() } else { onDismiss() }
                } label: {
                    Text(step == .intro ? "Skip" : "Close")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.30))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
            }
        }
        .frame(height: 36)
        .padding(.leading, 20)
        .animation(.easeInOut(duration: 0.2), value: narrator.isSpeaking)
    }

    private var progressStrip: some View {
        let visibleSteps = steps.filter { $0 != .intro && $0 != .done }
        let currentIdx   = visibleSteps.firstIndex(of: step) ?? 0
        return HStack(spacing: 4) {
            ForEach(0..<visibleSteps.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i <= currentIdx ? accent : Color.white.opacity(0.12))
                    .frame(height: 3)
                    .animation(.easeInOut(duration: 0.3), value: currentIdx)
            }
        }
        .frame(maxWidth: 240)
    }

    // MARK: - Content switcher

    @ViewBuilder
    private var content: some View {
        ZStack {
            stepView(for: step)
                .id(step)
                .transition(stepTransition)
                .animation(.easeInOut(duration: 0.28), value: step)
        }
    }

    private var stepTransition: AnyTransition {
        direction > 0
            ? .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                          removal:   .move(edge: .leading).combined(with: .opacity))
            : .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                          removal:   .move(edge: .trailing).combined(with: .opacity))
    }

    @ViewBuilder
    private func stepView(for s: OnboardingStep) -> some View {
        switch s {
        case .intro:                  IntroStep(onAdvance: advance)
        case .signIn:                 SignInStep(onAdvance: advance)
        case .voicePersona:           VoicePersonaStep(onAdvance: advance)
        case .knowledgeImport:        KnowledgeImportStep(onAdvance: advance)
        case .discovery:              DiscoveryStep(onAdvance: advance)
        case .permission(let perm):   PermissionStep(permission: perm, onAdvance: advance)
        case .agentFolder:            AgentFolderStep(onAdvance: advance)
        case .demoAgent:              DemoAgentStep(onAdvance: advance)
        case .demoFindInteresting:    DemoFindInterestingStep(onAdvance: advance)
        case .demoIdentify:           DemoIdentifyStep(onAdvance: advance)
        case .demoDraftReply:         DemoDraftReplyStep(onAdvance: advance)
        case .finale:                 FinaleStep(onAdvance: advance)
        case .paywall:                PaywallStep(onAdvance: { svc.completeSetup(); advance() })
        case .done:                   DoneStep(onDismiss: { svc.completeSetup(); onDismiss() })
        }
    }

    // MARK: - Navigation

    private func buildSteps() {
        var s: [OnboardingStep] = [.intro, .signIn, .voicePersona, .knowledgeImport, .discovery]
        for p in svc.missingPermissions() { s.append(.permission(p)) }
        s.append(.agentFolder)
        s.append(.demoAgent)
        s.append(.demoFindInteresting)
        s.append(.demoIdentify)
        s.append(.demoDraftReply)
        s.append(.finale)
        s.append(.paywall)
        s.append(.done)
        steps    = s
        stepIndex = 0
        step     = s[0]
    }

    private func advance() {
        OnboardingNarrator.shared.stop()
        direction = 1
        let next = stepIndex + 1
        guard next < steps.count else { onDismiss(); return }
        stepIndex = next
        withAnimation { step = steps[next] }
    }
}

// MARK: - Step 1: Intro video

private struct IntroStep: View {
    let onAdvance: () -> Void
    @State private var player: AVPlayer?
    @State private var hasVideo = false

    var body: some View {
        ZStack {
            if hasVideo, let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else {
                staticIntro
            }
        }
        .onAppear { setupVideo() }
    }

    // Static fallback when mira-intro.mp4 isn't in the bundle yet
    private var staticIntro: some View {
        VStack(spacing: 0) {
            Spacer()

            // Animated orb
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let ringW = CGFloat(80 + i * 28)
                    let ringO = 0.15 - Double(i) * 0.04
                    Circle()
                        .stroke(accent.opacity(ringO), lineWidth: 1)
                        .frame(width: ringW, height: ringW)
                }
                Circle()
                    .fill(
                        RadialGradient(colors: [accent.opacity(0.9), accent.opacity(0.3)],
                                       center: .center, startRadius: 0, endRadius: 30)
                    )
                    .frame(width: 60, height: 60)
            }
            .padding(.bottom, 36)

            Text("Meet Mira.")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.bottom, 12)

            Text("Your AI lives in your notch.\nVoice. Agents. Screen awareness.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.50))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.bottom, 48)

            Spacer()

            primaryButton("Get started", action: onAdvance)
                .padding(.horizontal, 40)
                .padding(.bottom, 36)
        }
    }

    private func setupVideo() {
        guard let url = Bundle.main.url(forResource: "mira-intro", withExtension: "mp4") else {
            return
        }
        let p = AVPlayer(url: url)
        // Auto-advance when video ends
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: p.currentItem,
            queue: .main
        ) { _ in onAdvance() }
        player   = p
        hasVideo = true
    }
}

// MARK: - Step 2: Sign-in

private struct SignInStep: View {
    let onAdvance: () -> Void
    @ObservedObject private var acct = AccountService.shared

    var body: some View {
        VStack(spacing: 0) {
            stepHeader(title: "Sign in to Mira.",
                       subtitle: "Your account powers voice, agents, and screen awareness — no API keys to manage.")

            if acct.isSignedIn {
                signedInView
            } else {
                ScrollView(showsIndicators: false) {
                    AuthView(compact: true, onAuthenticated: onAdvance)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 16)
                }
            }
        }
    }

    private var signedInView: some View {
        VStack(spacing: 0) {
            Spacer()
            successCheck
            Text("You're signed in.")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.bottom, 6)
            if let email = acct.currentUser?.email {
                Text(email)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.40))
            }
            Spacer()
            primaryButton("Continue", action: onAdvance)
                .padding(.horizontal, 40)
                .padding(.bottom, 36)
        }
    }
}

// MARK: - Step 3: Voice persona

private struct VoicePersonaStep: View {
    let onAdvance: () -> Void

    @State private var selected:  MiraPersona? = nil
    @State private var dragOffset: CGFloat     = 0
    @State private var audioPlayer: AVAudioPlayer? = nil
    @State private var playingVoice: MiraVoice?    = nil

    private let cardW: CGFloat = 200
    private let cardH: CGFloat = 190
    private let gap:   CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            stepHeader(title: "Choose your Mira.",
                       subtitle: "Each voice has its own style. Pick the one that feels right.")

            // Horizontal scrolling persona cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: gap) {
                    ForEach(MiraPersona.all) { persona in
                        personaCard(persona)
                            .onTapGesture { select(persona) }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
            }
            .frame(height: cardH + 24)

            Text("Tap a card to hear the voice.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
                .padding(.top, 8)

            Spacer()

            primaryButton(selected == nil ? "Choose a voice to continue" : "She's the one →") {
                guard let v = selected else { return }
                MiraVoice.saved = v.id
                onAdvance()
            }
            .opacity(selected == nil ? 0.35 : 1.0)
            .allowsHitTesting(selected != nil)
            .padding(.horizontal, 40)
            .padding(.bottom, 36)
        }
        .onAppear {
            // Pre-select saved voice if any
            if let match = MiraPersona.all.first(where: { $0.id == MiraVoice.saved }) {
                selected = match
            }
        }
    }

    private func personaCard(_ persona: MiraPersona) -> some View {
        let isSelected = selected?.id == persona.id
        let isPlaying  = playingVoice == persona.id
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected
                      ? persona.color.opacity(0.18)
                      : surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isSelected ? persona.color.opacity(0.60) : Color.white.opacity(0.06),
                                lineWidth: isSelected ? 1.5 : 0.5)
                )

            VStack(alignment: .leading, spacing: 0) {
                // Voice name + playing indicator
                HStack(spacing: 6) {
                    Text(persona.id.label.components(separatedBy: " — ").first ?? persona.id.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    if isPlaying {
                        MiniWaveform(color: persona.color)
                    }
                }
                .padding(.bottom, 8)

                // Tagline
                Text("\"" + persona.tagline + "\"")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                // Color pip
                Circle()
                    .fill(persona.color)
                    .frame(width: 8, height: 8)
            }
            .padding(16)
        }
        .frame(width: cardW, height: cardH)
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isSelected)
    }

    private func select(_ persona: MiraPersona) {
        selected = persona
        playPreview(for: persona)
    }

    private func playPreview(for persona: MiraPersona) {
        // Try bundled preview file first (mira-voice-preview-alloy.mp3, etc.)
        let resourceName = "mira-voice-preview-\(persona.id.rawValue)"
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "mp3"),
           let player = try? AVAudioPlayer(contentsOf: url) {
            audioPlayer = player
            playingVoice = persona.id
            player.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + player.duration) {
                if playingVoice == persona.id { playingVoice = nil }
            }
        }
    }
}

// Mini waveform for playing indicator
private struct MiniWaveform: View {
    let color: Color
    private static let heights: [CGFloat] = [3, 7, 5, 9, 4]
    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                Bar(maxH: Self.heights[i], color: color, delay: Double(i) * 0.08)
            }
        }
    }
    private struct Bar: View {
        let maxH: CGFloat; let color: Color; let delay: Double
        @State private var h: CGFloat = 2
        var body: some View {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 2, height: h)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true).delay(delay)) { h = maxH }
                }
        }
    }
}

// MARK: - Step 4: Discovery channel

// MARK: - Step: Import Knowledge

private struct KnowledgeImportStep: View {
    let onAdvance: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            stepHeader(
                title: "Let Mira know you.",
                subtitle: "Import your profile from ChatGPT, Claude, or any AI you already use — so Mira starts knowing you on day one. Stays on this Mac, never shared."
            )

            Spacer()

            KnowledgeImportView(embedded: true, onClose: onAdvance)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button("Skip for now") { onAdvance() }
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.30))
                .buttonStyle(.plain)
                .padding(.bottom, 28)
        }
    }
}

// MARK: - Step: Discovery

private struct DiscoveryStep: View {
    let onAdvance: () -> Void
    @StateObject private var svc = OnboardingService.shared
    @State private var picked:    DiscoveryChannel? = nil
    @State private var otherText: String            = ""

    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 0) {
            stepHeader(title: "How did you find Mira?",
                       subtitle: "Helps us know where to focus. Takes one tap.")

            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(DiscoveryChannel.allCases) { channel in
                    channelTile(channel)
                }
            }
            .padding(.horizontal, 28)

            if picked == .other {
                TextField("Tell us more…", text: $otherText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
            }

            Spacer()

            HStack(spacing: 12) {
                Button("Skip") { onAdvance() }
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.30))
                    .buttonStyle(.plain)

                primaryButton(picked == nil ? "Pick one to continue" : "Continue →") {
                    svc.discoveryChannel      = picked
                    svc.discoveryChannelOther = otherText
                    onAdvance()
                }
                .opacity(picked == nil ? 0.35 : 1.0)
                .allowsHitTesting(picked != nil)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 36)
        }
    }

    private func channelTile(_ channel: DiscoveryChannel) -> some View {
        let isSelected = picked == channel
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { picked = channel }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: channel.icon)
                    .font(.system(size: 18))
                    .foregroundColor(isSelected ? accent : .white.opacity(0.45))
                Text(channel.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.45))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(isSelected ? accent.opacity(0.15) : surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.50) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Step 5: Permission coaching (one screen per permission)

private struct PermissionStep: View {
    let permission: MiraPermission
    let onAdvance:  () -> Void

    @State private var coachStep:  Int      = 0
    @State private var granted:    Bool     = false
    @State private var orbOffset:  CGFloat  = 0
    @State private var pulseScale: CGFloat  = 1.0
    @State private var celebScale: CGFloat  = 0.0
    @State private var pollTask:   Task<Void, Never>? = nil
    @State private var celebrating = false

    var body: some View {
        VStack(spacing: 0) {
            // Permission title + step counter handled by outer progress bar
            stepHeader(title: permission.title + " access.",
                       subtitle: permission.unlock)

            // Permission coach area
            ZStack {
                // Background radial glow
                RadialGradient(
                    colors: [accent.opacity(0.12), Color.clear],
                    center: .center, startRadius: 0, endRadius: 120
                )
                .frame(width: 240, height: 180)
                .blur(radius: 20)

                // Coach orb
                ZStack {
                    // Outer pulse rings
                    ForEach(0..<2, id: \.self) { i in
                        Circle()
                            .stroke(accent.opacity(granted ? 0 : 0.10 - Double(i) * 0.04), lineWidth: 1)
                            .frame(width: CGFloat(50 + i * 20), height: CGFloat(50 + i * 20))
                            .scaleEffect(pulseScale)
                    }

                    // Core orb
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: granted
                                    ? [Color(red: 0.11, green: 0.73, blue: 0.33).opacity(0.9),
                                       Color(red: 0.11, green: 0.73, blue: 0.33).opacity(0.5)]
                                    : [accent.opacity(0.9), accent.opacity(0.5)],
                                center: .center, startRadius: 0, endRadius: 22
                            )
                        )
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: granted ? "checkmark" : permission.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                        )
                        .scaleEffect(celebrating ? 1.4 : 1.0)
                        .shadow(color: (granted
                                        ? Color(red: 0.11, green: 0.73, blue: 0.33)
                                        : accent).opacity(0.60),
                                radius: 12, x: 0, y: 0)
                }
                .offset(y: orbOffset)
                .animation(.spring(response: 0.5, dampingFraction: 0.65), value: orbOffset)

                // Speech bubble
                if !granted {
                    speechBubble
                        .offset(y: orbOffset - 50)
                        .animation(.spring(response: 0.4, dampingFraction: 0.70), value: orbOffset)
                        .animation(.easeInOut(duration: 0.2), value: coachStep)
                }
            }
            .frame(height: 200)
            .padding(.vertical, 8)

            // Step-by-step instruction text
            if !granted {
                let steps = permission.coachSteps
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { idx, text in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(idx <= coachStep ? accent : Color.white.opacity(0.12))
                                .frame(width: 6, height: 6)
                                .padding(.top, 5)
                            Text(text)
                                .font(.system(size: 12))
                                .foregroundColor(idx == coachStep
                                                 ? .white.opacity(0.85)
                                                 : .white.opacity(0.30))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 40)
            }

            Spacer()

            if granted {
                VStack(spacing: 12) {
                    Text(permission.title + " is ready.")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(red: 0.11, green: 0.73, blue: 0.33))

                    primaryButton("Continue →", action: onAdvance)
                        .padding(.horizontal, 40)
                }
                .padding(.bottom, 36)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                VStack(spacing: 10) {
                    if permission == .microphone {
                        primaryButton("Allow Microphone") {
                            Task {
                                let ok = await OnboardingService.shared.requestMicrophone()
                                if ok { celebrate() }
                            }
                        }
                        .padding(.horizontal, 40)
                    } else {
                        primaryButton("Open System Settings") {
                            coachStep = min(coachStep + 1, permission.coachSteps.count - 1)
                            orbOffset = 16
                            OnboardingService.shared.openSettings(for: permission)
                        }
                        .padding(.horizontal, 40)
                    }

                    if permission.needsRelaunch {
                        Text("macOS will ask you to quit and reopen Mira.")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }
                .padding(.bottom, 36)
            }
        }
        .onAppear {
            startPulse()
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private var speechBubble: some View {
        let steps = permission.coachSteps
        let text  = steps.indices.contains(coachStep) ? steps[coachStep] : ""
        return ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                            )
                    )
                    .frame(maxWidth: 220)

                // Bubble tail
                Triangle()
                    .fill(surface)
                    .frame(width: 12, height: 7)
                    .padding(.top, -1)
            }
        }
    }

    private func startPulse() {
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pulseScale = 1.12
        }
    }

    private func startPolling() {
        pollTask = Task {
            while !Task.isCancelled {
                if permission.isGranted && !granted {
                    await MainActor.run { celebrate() }
                    return
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }

    private func celebrate() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
            celebrating = true
            granted     = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation { celebrating = false }
        }
    }
}

// Triangle for bubble tail
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Step 6: Agent folder

private struct AgentFolderStep: View {
    let onAdvance: () -> Void
    @StateObject private var svc = OnboardingService.shared
    @State private var folderPath = ""

    var body: some View {
        VStack(spacing: 0) {
            stepHeader(title: "Where should Mira work?",
                       subtitle: "Agents create files here by default. You can change this in Settings anytime.")

            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                    )

                VStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 28))
                        .foregroundColor(accent)

                    Text(folderPath.isEmpty ? svc.agentFolderPath : folderPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.50))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    Button("Change Folder") {
                        pickFolder()
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(accent)
                    .buttonStyle(.plain)
                }
                .padding(24)
            }
            .padding(.horizontal, 40)

            Spacer()

            primaryButton("Use this folder →") {
                svc.createDefaultAgentFolder()
                onAdvance()
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 36)
        }
        .onAppear { folderPath = svc.agentFolderPath }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles      = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        svc.agentFolderURL = url
        folderPath = url.path
    }
}

// MARK: - Step 7: Demo agent

private struct DemoAgentStep: View {
    let onAdvance: () -> Void

    @State private var launched  = false
    @State private var jobId:    String? = nil
    @State private var dotCount  = 0
    @State private var dotTimer: Timer? = nil

    private let demoPrompt = "Build a beautiful single-page HTML website with the title 'Hello from Mira' using a dark design with a glowing blue accent. Add a short tagline and make it visually impressive."

    var body: some View {
        VStack(spacing: 0) {
            stepHeader(title: "See Mira in action.",
                       subtitle: "Watch a real agent run — right now, during setup.")

            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(launched ? accent.opacity(0.25) : Color.white.opacity(0.07), lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(launched ? accent.opacity(0.18) : Color.white.opacity(0.06))
                                .frame(width: 32, height: 32)
                            Image(systemName: launched ? "sparkles" : "cpu")
                                .font(.system(size: 13))
                                .foregroundColor(launched ? accent : .white.opacity(0.40))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Demo agent")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.70))
                            Text(launched ? runningLabel : "Ready to run")
                                .font(.system(size: 11))
                                .foregroundColor(launched ? accent : .white.opacity(0.30))
                        }
                        Spacer()
                    }

                    Text(demoPrompt)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
            .padding(.horizontal, 40)

            Spacer()

            if !launched {
                primaryButton("Run the demo") { runDemo() }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 16)

                Button("Skip for now") { onAdvance() }
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.25))
                    .buttonStyle(.plain)
                    .padding(.bottom, 28)
            } else {
                VStack(spacing: 10) {
                    Text("Running in the Agents tab. You can watch it live.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.40))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    primaryButton("Continue →", action: onAdvance)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 36)
                }
            }
        }
        .onDisappear { dotTimer?.invalidate() }
    }

    private var runningLabel: String {
        "Working" + String(repeating: ".", count: dotCount + 1)
    }

    private func runDemo() {
        let key = MiraState.shared?.effectiveAPIKey ?? AppSecrets.anthropicAPIKey
        guard !key.isEmpty else { onAdvance(); return }
        let job = AgentJobStore.shared.submitJob(prompt: demoPrompt,
                                                  apiKey: key,
                                                  buildMode: .pro)
        jobId    = job.id.uuidString
        launched = true
        dotTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            Task { @MainActor in dotCount = (dotCount + 1) % 3 }
        }
        NotificationCenter.default.post(name: .miraAgentFlightLaunched,
                                         object: nil,
                                         userInfo: ["jobId": job.id.uuidString])
    }
}

// MARK: - Step 8: Paywall / plan selection

private struct PaywallStep: View {
    let onAdvance: () -> Void
    @State private var hasVideo    = false
    @State private var player: AVPlayer?
    @State private var purchasing: SubscriptionPlan? = nil
    @State private var errorMsg: String? = nil

    private let ultraAccent = Color(red: 0.75, green: 0.45, blue: 0.95)

    var body: some View {
        VStack(spacing: 0) {
            if hasVideo, let player {
                VideoPlayer(player: player)
                    .frame(height: 160)
                    .clipped()
                    .onAppear { player.play() }
            } else {
                staticPaywallBanner
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    if let err = errorMsg {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                    }

                    planCard(
                        name: "Free",
                        price: "$0",
                        features: ["5 agent tasks / month", "Voice & chat", "Screen guidance"],
                        planAccent: Color.white.opacity(0.30),
                        cta: "Start free",
                        loading: false
                    ) { onAdvance() }

                    planCard(
                        name: "Pro",
                        price: "$19.99/mo",
                        features: ["100 agent tasks / month", "Everything in Free", "Background agents", "Priority speed"],
                        planAccent: accent,
                        cta: "Upgrade to Pro",
                        loading: purchasing == .pro
                    ) { purchase(.pro) }

                    planCard(
                        name: "Ultra",
                        price: "$49.99/mo",
                        features: ["500 agent tasks / month", "Everything in Pro", "Multi-agent workflows", "Ultra speed"],
                        planAccent: ultraAccent,
                        cta: "Upgrade to Ultra",
                        loading: purchasing == .ultra
                    ) { purchase(.ultra) }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
            }
        }
        .onAppear { setupVideo() }
    }

    private func purchase(_ plan: SubscriptionPlan) {
        guard purchasing == nil else { return }
        errorMsg = nil
        purchasing = plan
        Task {
            do {
                try await StripePurchaseService.shared.startCheckout(plan: plan)
                // Browser opened — advance so user isn't stuck on this screen.
                // Plan update happens via Stripe webhook in the background.
                onAdvance()
            } catch {
                errorMsg = error.localizedDescription
            }
            purchasing = nil
        }
    }

    private var staticPaywallBanner: some View {
        ZStack {
            LinearGradient(
                colors: [accent.opacity(0.25), Color(red: 0.35, green: 0.10, blue: 0.55).opacity(0.25)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 6) {
                Text("Unlock the full Mira.")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Run agents in the background. All day.")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .frame(height: 120)
    }

    private func planCard(name: String, price: String, features: [String],
                          planAccent: Color, cta: String, loading: Bool,
                          action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Text(price)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                Button(action: action) {
                    if loading {
                        ProgressView().scaleEffect(0.65).frame(width: 60, height: 22)
                    } else {
                        Text(cta)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(planAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(planAccent.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
                .buttonStyle(.plain)
                .disabled(loading)
            }

            Divider().background(Color.white.opacity(0.06))

            VStack(alignment: .leading, spacing: 5) {
                ForEach(features, id: \.self) { feat in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(planAccent)
                        Text(feat)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.60))
                    }
                }
            }
        }
        .padding(14)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(planAccent.opacity(0.20), lineWidth: 0.5)
        )
    }

    private func setupVideo() {
        guard let url = Bundle.main.url(forResource: "mira-paywall", withExtension: "mp4") else { return }
        let p = AVPlayer(url: url)
        p.actionAtItemEnd = .none
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: p.currentItem, queue: .main
        ) { _ in p.seek(to: .zero); p.play() }
        player   = p
        hasVideo = true
    }
}

// MARK: - Step 9: Done

private struct DoneStep: View {
    let onDismiss: () -> Void
    @State private var scale: CGFloat = 0.5
    @State private var opacity: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color(red: 0.11, green: 0.73, blue: 0.33).opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(Color(red: 0.11, green: 0.73, blue: 0.33))
            }
            .scaleEffect(scale)
            .opacity(opacity)
            .padding(.bottom, 28)

            Text("Mira is ready.")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .opacity(opacity)
                .padding(.bottom, 10)

            Text("Hover the notch to open. Hold ⌃⌥ to talk.")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.40))
                .multilineTextAlignment(.center)
                .opacity(opacity)
                .padding(.horizontal, 40)

            Spacer()

            primaryButton("Start using Mira") { onDismiss() }
                .padding(.horizontal, 40)
                .padding(.bottom, 36)
                .opacity(opacity)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.60)) { scale = 1.0 }
            withAnimation(.easeOut(duration: 0.35).delay(0.1)) { opacity = 1.0 }
        }
    }
}

// MARK: - Capability demo steps (HeyClicky-parity onboarding)

/// Shared visual for a running demo: an icon in an accent circle + a status line.
private func demoBadge(icon: String, label: String, active: Bool = true) -> some View {
    VStack(spacing: 14) {
        ZStack {
            Circle()
                .fill(active ? accent.opacity(0.16) : Color.white.opacity(0.06))
                .frame(width: 72, height: 72)
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(active ? accent : .white.opacity(0.40))
        }
        Text(label)
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.55))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
    }
}

private func skipDemoButton(_ action: @escaping () -> Void) -> some View {
    Button("Skip demo", action: action)
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.25))
        .buttonStyle(.plain)
        .padding(.bottom, 28)
}

/// Demo 1 — Mira looks at the screen and highlights something notable.
private struct DemoFindInterestingStep: View {
    let onAdvance: () -> Void
    @State private var advanced = false
    @State private var watchdog: Timer?
    @State private var phase = "Looking at your screen…"

    var body: some View {
        VStack(spacing: 0) {
            stepHeader(title: "Watch me look at your screen.",
                       subtitle: "I'll spot something worth pointing out — right now.")
            Spacer()
            demoBadge(icon: "eye", label: phase)
            Spacer()
            skipDemoButton { finish() }
        }
        .onAppear { run() }
        .onDisappear { watchdog?.invalidate() }
    }

    private func run() {
        startWatchdog(15) { finish() }
        Task {
            _ = await OnboardingDemoRunner.shared.findSomethingInteresting()
            phase = "That's screen awareness."
            try? await Task.sleep(nanoseconds: 800_000_000)
            finish()
        }
    }

    private func startWatchdog(_ seconds: TimeInterval, _ fire: @escaping () -> Void) {
        watchdog = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in fire() }
    }

    private func finish() {
        guard !advanced else { return }
        advanced = true
        watchdog?.invalidate()
        onAdvance()
    }
}

/// Demo 2 — user clicks anything; Mira identifies it aloud.
private struct DemoIdentifyStep: View {
    let onAdvance: () -> Void
    @State private var advanced = false
    @State private var watchdog: Timer?
    @State private var phase = "Click anything on your screen…"

    var body: some View {
        VStack(spacing: 0) {
            stepHeader(title: "Point me at anything.",
                       subtitle: "Click something on screen and I'll tell you what it is.")
            Spacer()
            demoBadge(icon: "hand.point.up.left", label: phase)
            Spacer()
            skipDemoButton { finish() }
        }
        .onAppear { run() }
        .onDisappear { watchdog?.invalidate() }
    }

    private func run() {
        // 15s safety net above the runner's own 10s click timeout.
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in finish() }
        Task {
            await OnboardingDemoRunner.shared.identifyUnderCursor()
            phase = "I can read and act on anything you see."
            try? await Task.sleep(nanoseconds: 600_000_000)
            finish()
        }
    }

    private func finish() {
        guard !advanced else { return }
        advanced = true
        watchdog?.invalidate()
        onAdvance()
    }
}

/// Demo 3 — Mira drafts a reply; the user approves before anything happens.
private struct DemoDraftReplyStep: View {
    let onAdvance: () -> Void
    @State private var advanced = false
    @State private var watchdog: Timer?
    @State private var draft: String?
    @State private var phase = "Drafting a reply from your screen…"

    var body: some View {
        VStack(spacing: 0) {
            stepHeader(title: "I do things — but only with your OK.",
                       subtitle: "I drafted a reply. Nothing happens until you approve it.")
            Spacer()
            if let draft {
                draftCard(draft)
            } else {
                demoBadge(icon: "square.and.pencil", label: phase)
            }
            Spacer()
            skipDemoButton { finish() }
        }
        .onAppear { run() }
        .onDisappear { watchdog?.invalidate() }
    }

    private func draftCard(_ text: String) -> some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(accent.opacity(0.25), lineWidth: 0.5))
                .overlay(
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.80))
                        .multilineTextAlignment(.leading)
                        .padding(18),
                    alignment: .topLeading)
                .frame(height: 120)
                .padding(.horizontal, 40)

            HStack(spacing: 12) {
                Button("Discard") { finish() }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.45))
                    .font(.system(size: 13))
                primaryButton("Approve") { approve(text) }
                    .frame(maxWidth: 180)
            }
            .padding(.horizontal, 40)
        }
    }

    private func run() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in finish() }
        Task {
            let result = await OnboardingDemoRunner.shared.draftReply()
            guard let result else { finish(); return }   // graceful: no draft → advance
            withAnimation { draft = result }
        }
    }

    /// Safe, reversible "action": copy to clipboard so nothing is sent anywhere.
    private func approve(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Task {
            await OnboardingNarrator.shared.speakAndWait("Copied — you're always in control of what I do.")
            finish()
        }
    }

    private func finish() {
        guard !advanced else { return }
        advanced = true
        watchdog?.invalidate()
        onAdvance()
    }
}

/// Finale — a personalized welcome page built from the user's real installed apps.
private struct FinaleStep: View {
    let onAdvance: () -> Void
    @State private var pageURL: URL?
    @State private var generated = false

    private var userName: String {
        MemoryStore.shared.memory(forKey: "user_name")?.value
            ?? MemoryStore.shared.memory(forKey: "name")?.value
            ?? NSFullUserName().components(separatedBy: " ").first
            ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            stepHeader(title: "One more thing.",
                       subtitle: "I built you a welcome page — from the apps already on your Mac.")
            Spacer()
            demoBadge(icon: generated ? "checkmark.seal.fill" : "wand.and.stars",
                      label: generated ? "Opened in your browser." : "Personalizing…")
            Spacer()
            primaryButton(generated ? "Continue →" : "…") { onAdvance() }
                .padding(.horizontal, 40)
                .padding(.bottom, 16)
                .disabled(!generated)
                .opacity(generated ? 1 : 0.4)
            if generated, let pageURL {
                Button("Reopen page") { NSWorkspace.shared.open(pageURL) }
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.30))
                    .buttonStyle(.plain)
                    .padding(.bottom, 28)
            } else {
                Color.clear.frame(height: 28)
            }
        }
        .onAppear { run() }
    }

    private func run() {
        Task {
            let url = OnboardingDemoRunner.shared.generateFinalePage(name: userName)
            withAnimation {
                pageURL = url
                generated = true
            }
        }
    }
}

// MARK: - Shared helpers

private func stepHeader(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title)
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundColor(.white)
        Text(subtitle)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.40))
            .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 28)
    .padding(.top, 10)
    .padding(.bottom, 18)
}

private var successCheck: some View {
    ZStack {
        Circle()
            .fill(Color(red: 0.11, green: 0.73, blue: 0.33).opacity(0.12))
            .frame(width: 64, height: 64)
        Image(systemName: "checkmark")
            .font(.system(size: 24, weight: .semibold))
            .foregroundColor(Color(red: 0.11, green: 0.73, blue: 0.33))
    }
    .padding(.bottom, 18)
}

private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(label)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(accent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
}

// MARK: - Narrator waveform indicator

private struct NarratorWaveform: View {
    private static let heights: [CGFloat] = [4, 8, 6, 10, 5, 9, 4]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.heights.count, id: \.self) { i in
                Bar(maxH: Self.heights[i], delay: Double(i) * 0.07)
            }
        }
    }
    private struct Bar: View {
        let maxH: CGFloat
        let delay: Double
        @State private var h: CGFloat = 2
        var body: some View {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent.opacity(0.70))
                .frame(width: 2.5, height: h)
                .onAppear {
                    withAnimation(
                        .easeInOut(duration: 0.45)
                        .repeatForever(autoreverses: true)
                        .delay(delay)
                    ) { h = maxH }
                }
        }
    }
}
