import SwiftUI

// Renders inside the notch island when onboarding is active.
// Layout: physical-notch spacer → animated eyes → step content.

struct NotchOnboardingView: View {
    let notchHeight: CGFloat

    @ObservedObject private var manager  = NotchOnboardingManager.shared
    @ObservedObject private var narrator = OnboardingNarrator.shared

    var body: some View {
        VStack(spacing: 0) {
            // Skip past the physical notch cutout so eyes appear below it
            Spacer().frame(height: notchHeight + 6)

            MiraEyesView(isSpeaking: narrator.isSpeaking, stepGranted: manager.stepGranted)
                .frame(height: 64)

            Spacer().frame(height: 16)

            // Per-step content
            stepContent
                .padding(.horizontal, 28)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal:   .move(edge: .leading).combined(with: .opacity)
                ))
                .id(manager.step)
                .animation(.easeInOut(duration: 0.25), value: manager.step)

            Spacer(minLength: 12)

            // Skip button — always available
            if manager.step != .done {
                Button("Skip setup") { manager.skip() }
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.20))
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch manager.step {
        case .welcome:
            demoCard(
                icon: "sparkles",
                color: Color(red: 0.55, green: 0.38, blue: 1.0),
                headline: "Meet Mira",
                subtitle: "The AI that lives in your notch\nand actually does things."
            )

        case .voice:
            if manager.isDemoActive {
                VoiceWaveformCard()
            } else {
                demoCard(
                    icon: "mic.fill",
                    color: Color(red: 0.28, green: 0.72, blue: 1.0),
                    headline: "Voice, always on",
                    subtitle: "Hold ⌃⌥V anywhere to talk.\nNo switching apps. No typing."
                )
            }

        case .screenGuidance:
            demoCard(
                icon: "cursorarrow.rays",
                color: Color(red: 1.0, green: 0.65, blue: 0.20),
                headline: "I see your screen",
                subtitle: "Hold ⌃⌥D to draw on anything.\nI'll walk you through it."
            )

        case .autonomy:
            demoCard(
                icon: "hand.tap.fill",
                color: Color(red: 0.20, green: 0.85, blue: 0.60),
                headline: "I take over",
                subtitle: "I click, type, and navigate\nyour Mac for you — live."
            )

        case .agents:
            if manager.isDemoActive {
                AgentProgressCard()
            } else {
                demoCard(
                    icon: "gearshape.2.fill",
                    color: Color(red: 1.0, green: 0.35, blue: 0.50),
                    headline: "Background agents",
                    subtitle: "Build sites, research, batch tasks.\nI work while you do other things."
                )
            }

        case .signIn:
            VStack(spacing: 10) {
                Text("Sign in to continue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.70))
                ScrollView(showsIndicators: false) {
                    AuthView(compact: true, onAuthenticated: {})
                        .frame(maxWidth: 380)
                }
            }

        case .microphone:
            permissionRow(
                icon: "mic.fill",
                label: "Microphone",
                granted: MiraPermission.microphone.isGranted
            )

        case .screenRecording:
            VStack(spacing: 10) {
                permissionRow(
                    icon: "rectangle.on.rectangle",
                    label: "Screen Recording",
                    granted: MiraPermission.screenRecording.isGranted
                )
                if !MiraPermission.screenRecording.isGranted {
                    settingsButton(for: .screenRecording)
                }
            }

        case .accessibility:
            VStack(spacing: 10) {
                permissionRow(
                    icon: "accessibility",
                    label: "Accessibility",
                    granted: MiraPermission.accessibility.isGranted
                )
                if !MiraPermission.accessibility.isGranted {
                    settingsButton(for: .accessibility)
                }
            }

        case .done:
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Color(red: 0.18, green: 0.80, blue: 0.44))
                Text("You're all set.")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
        }
    }

    private func demoCard(icon: String, color: Color, headline: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(color)
            }
            Text(headline)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.50))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
    }

    private func permissionRow(icon: String, label: String, granted: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(granted
                          ? Color(red: 0.18, green: 0.80, blue: 0.44).opacity(0.18)
                          : Color.white.opacity(0.08))
                    .frame(width: 34, height: 34)
                Image(systemName: granted ? "checkmark" : icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(granted
                                     ? Color(red: 0.18, green: 0.80, blue: 0.44)
                                     : .white.opacity(0.45))
            }
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(granted ? .white : .white.opacity(0.55))
            Spacer()
            if granted {
                Text("Ready")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(red: 0.18, green: 0.80, blue: 0.44))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: granted)
    }

    private func settingsButton(for permission: MiraPermission) -> some View {
        Button("Open System Settings") {
            OnboardingService.shared.openSettings(for: permission)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(DS.Colors.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(DS.Colors.accent.opacity(0.12))
        .clipShape(Capsule())
        .buttonStyle(.plain)
    }
}

// MARK: - Animated eyes

struct MiraEyesView: View {
    var isSpeaking:  Bool
    var stepGranted: Bool

    private let eyeW:  CGFloat = 20
    private let baseH: CGFloat = 16
    private let gap:   CGFloat = 24

    @State private var blinkScale:  CGFloat = 1.0
    @State private var speakFactor: CGFloat = 1.0
    @State private var joyScale:    CGFloat = 1.0
    @State private var talkBob:     CGFloat = 0.0

    @State private var blinkTimer: Timer?
    @State private var talkTask:   Task<Void, Never>?

    private var eyeH: CGFloat { max(baseH * blinkScale * speakFactor * joyScale, 1.5) }

    var body: some View {
        HStack(spacing: gap) {
            eyeCapsule(leftSide: true)
            eyeCapsule(leftSide: false)
        }
        .frame(maxWidth: .infinity)
        .onAppear { scheduleBlink() }
        .onDisappear {
            blinkTimer?.invalidate()
            blinkTimer = nil
            talkTask?.cancel()
        }
        .onChange(of: isSpeaking) { _, speaking in
            withAnimation(.easeInOut(duration: 0.18)) {
                speakFactor = speaking ? 0.68 : 1.0
            }
            if speaking { startTalking() } else { stopTalking() }
        }
        .onChange(of: stepGranted) { _, granted in
            if granted { playJoy() }
        }
    }

    private func eyeCapsule(leftSide: Bool) -> some View {
        Capsule()
            .fill(Color.white)
            .frame(width: eyeW, height: eyeH)
            .offset(y: leftSide ? -talkBob : talkBob)
            .animation(.easeInOut(duration: 0.12), value: eyeH)
    }

    // MARK: - Blink

    private func scheduleBlink() {
        let delay = Double.random(in: 2.8 ... 4.5)
        blinkTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in blink() }
        }
    }

    private func blink() {
        withAnimation(.easeInOut(duration: 0.055)) { blinkScale = 0.04 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            withAnimation(.spring(response: 0.14, dampingFraction: 0.58)) { blinkScale = 1.0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { scheduleBlink() }
        }
    }

    // MARK: - Talk bob (eyes alternate up/down)

    private func startTalking() {
        talkTask?.cancel()
        talkTask = Task { @MainActor in
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.20)) { talkBob = 2.5 }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.20)) { talkBob = -2.5 }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func stopTalking() {
        talkTask?.cancel()
        talkTask = nil
        withAnimation(.easeOut(duration: 0.18)) { talkBob = 0 }
    }

    // MARK: - Joy bounce (permission granted)

    private func playJoy() {
        withAnimation(.spring(response: 0.14, dampingFraction: 0.42)) { joyScale = 0.20 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.38)) { joyScale = 1.45 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
            withAnimation(.spring(response: 0.20, dampingFraction: 0.68)) { joyScale = 1.0 }
        }
    }
}

// MARK: - Voice Waveform Demo Card

struct VoiceWaveformCard: View {
    private let barCount = 20
    private let accentColor = Color(red: 0.28, green: 0.72, blue: 1.0)
    @State private var heights: [CGFloat] = Array(repeating: 4, count: 20)
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 12) {
            // Animated bars
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(accentColor.opacity(0.7 + 0.3 * Double(heights[i]) / 28))
                        .frame(width: 3, height: heights[i])
                        .animation(.easeInOut(duration: 0.18), value: heights[i])
                }
            }
            .frame(height: 32)

            Text("Listening…")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(accentColor)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
                Task { @MainActor in
                    for i in 0..<barCount {
                        heights[i] = CGFloat.random(in: 4...28)
                    }
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

// MARK: - Agent Progress Demo Card

struct AgentProgressCard: View {
    private let accentColor = Color(red: 1.0, green: 0.35, blue: 0.50)
    @State private var progress: CGFloat = 0
    @State private var rotation: Double  = 0
    @State private var phase: Int        = 0  // 0=running 1=done

    private let phases = ["Building structure…", "Writing content…", "Deploying…", "Done ✓"]

    var body: some View {
        VStack(spacing: 10) {
            // Spinning gear or checkmark
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                if phase < 3 {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(accentColor)
                        .rotationEffect(.degrees(rotation))
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color(red: 0.18, green: 0.80, blue: 0.44))
                }
            }

            Text(phases[min(phase, phases.count - 1)])
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.75))
                .animation(.easeInOut(duration: 0.25), value: phase)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10)).frame(height: 4)
                    Capsule()
                        .fill(phase < 3 ? accentColor : Color(red: 0.18, green: 0.80, blue: 0.44))
                        .frame(width: geo.size.width * progress, height: 4)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
        .onAppear { runDemo() }
    }

    private func runDemo() {
        // Spin gear
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
            rotation = 360
        }
        // Fill progress bar over ~3s in segments
        let milestones: [(Double, CGFloat, Int)] = [
            (0.6, 0.32, 0),
            (1.1, 0.58, 1),
            (1.7, 0.80, 2),
            (2.3, 1.00, 3),
        ]
        for (delay, prog, ph) in milestones {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeInOut(duration: 0.5)) { progress = prog }
                phase = ph
            }
        }
    }
}
