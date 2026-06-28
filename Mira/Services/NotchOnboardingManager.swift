import AVFoundation
import CoreGraphics
import AppKit
import Foundation

// Drives the fully-autonomous notch onboarding flow.
// Mira speaks each step, auto-advances on narration completion, and only asks
// for the three permissions that matter on the Free plan.

@MainActor
final class NotchOnboardingManager: ObservableObject {
    static let shared = NotchOnboardingManager()
    private init() {}

    enum Step: Equatable {
        case welcome, voice, screenGuidance, autonomy, agents, signIn, microphone, screenRecording, accessibility, done
    }

    @Published private(set) var isActive    = false
    @Published private(set) var step: Step  = .welcome
    @Published private(set) var stepGranted = false   // triggers joy eye-animation
    @Published private(set) var isDemoActive = false  // triggers animated demo card state

    private weak var animController: AnimationController?
    private var flowTask: Task<Void, Never>?

    // MARK: - Public API

    func start(with animController: AnimationController) {
        guard !isActive else { return }
        self.animController   = animController
        isActive              = true
        step                  = .welcome
        animController.isOnboarding      = true
        animController.currentExpandedH  = 270
        // Silence the always-on realtime voice so it can't interrupt narration
        RealtimeVoiceService.shared.disconnectAlwaysOn()
        // expandForShortcut() is wired in NotchManager via .miraOnboardingStarted
        NotificationCenter.default.post(name: .miraOnboardingStarted, object: nil)
        flowTask = Task { await runFlow() }
    }

    func skip() {
        flowTask?.cancel()
        flowTask = nil
        finishOnboarding()
    }

    // MARK: - Flow

    private func runFlow() async {
        // Kill the always-on realtime voice so it can't speak over the narration.
        // Called here (inside the Task) so it runs after expandForShortcut() fires.
        RealtimeVoiceService.shared.disconnectAlwaysOn()

        let narrator = OnboardingNarrator.shared
        let svc      = OnboardingService.shared

        // ── Sign in FIRST so all demo narration uses OpenAI TTS ──────────────
        if !AccountService.shared.isSignedIn {
            step = .welcome
            // Brief system-TTS welcome before auth is available
            await narrator.speakAndWait("Hey — I'm Mira. Sign in real quick and then I'll show you everything I can do.")
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }

            step = .signIn
            animController?.currentExpandedH = 420
            while !AccountService.shared.isSignedIn && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else { return }
            animController?.currentExpandedH = 270
            // First OpenAI TTS line — user is now signed in
            await narrator.speakAndWait("Perfect. Now let me show you what I can do.")
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
        } else {
            step = .welcome
            await narrator.speakAndWait("Hey — I'm Mira. I live right here in your Mac's notch. Let me show you what I can do.")
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
        }

        // ── Demo steps — all OpenAI TTS from here ────────────────────────────

        // Voice
        step = .voice
        isDemoActive = true
        await narrator.speakAndWait("My voice is always on. Hold Control-Option-V anywhere on your Mac and I wake up instantly, ready to listen. Ask me to write an email, summarise what's on your screen, set a reminder, look something up — I'll answer and act. No switching apps, no typing, no waiting.")
        // Hold waveform visible briefly after narration ends
        try? await Task.sleep(nanoseconds: 800_000_000)
        isDemoActive = false
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }

        // Screen Guidance
        step = .screenGuidance
        // Launch overlay concurrent with narration so the spotlight appears mid-speech
        async let _overlay: Void = OnboardingDemoOverlay.shared.showScreenGuidanceDemo()
        await narrator.speakAndWait("I can see exactly what you're looking at too. Hold Control-Option-D and draw on your screen to show me anything — a button you can't find, a form that's confusing, a chart you want explained. I'll point to the exact thing and walk you through it step by step, in any app.")
        _ = await _overlay
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }

        // Autonomy
        step = .autonomy
        await narrator.speakAndWait("Here's where I'm different from every other assistant. I can actually take over your Mac and do things for you. Fill out a form. Click through a settings screen. Navigate a complex workflow. You describe the task, I execute it — you watch it happen in real time.")
        // Now actually move the cursor while user watches
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        await OnboardingDemoOverlay.shared.showAutonomyDemo()
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }

        // Agents
        step = .agents
        isDemoActive = true
        await narrator.speakAndWait("And for bigger projects, I run background agents. Ask me to build a landing page, research competitors, process a batch of files, or connect your tools. I'll spin up an agent, work in the background, and report back when it's done. I'm always working, even when you're not watching.")
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        isDemoActive = false
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }

        // Microphone
        if !MiraPermission.microphone.isGranted {
            step = .microphone
            await narrator.speakAndWait("I need to hear you — requesting microphone access now.")
            let granted = await svc.requestMicrophone()
            if granted {
                await flashGranted()
                await narrator.speakAndWait("Got it.")
            } else {
                await narrator.speakAndWait("No problem — you can enable that in System Settings anytime.")
            }
        }
        guard !Task.isCancelled else { return }

        // Screen recording
        if !MiraPermission.screenRecording.isGranted {
            step = .screenRecording
            await narrator.speakAndWait("Now I need to see your screen so I can guide you through any app. Open System Settings and flip my toggle on.")
            svc.openSettings(for: .screenRecording)
            while !MiraPermission.screenRecording.isGranted && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            guard !Task.isCancelled else { return }
            await flashGranted()
            await narrator.speakAndWait("Screen Recording is on. Got it.")
        }
        guard !Task.isCancelled else { return }

        // Accessibility
        if !MiraPermission.accessibility.isGranted {
            step = .accessibility
            await narrator.speakAndWait("Last one. Accessibility lets me click and type in your apps when you ask. System Settings, find Mira, flip the toggle.")
            svc.openSettings(for: .accessibility)
            while !MiraPermission.accessibility.isGranted && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            guard !Task.isCancelled else { return }
            await flashGranted()
            await narrator.speakAndWait("Amazing.")
        }
        guard !Task.isCancelled else { return }

        // Done
        step = .done
        await narrator.speakAndWait("You're all set — and I'm ready to go. Hover the notch to open me anytime, or hold Control-Option to talk. And everything I just showed you? That's just the beginning. Depending on the plan you're on, I can run full background agents, connect your apps, and handle entire workflows for you. I'm right here whenever you need me.")
        try? await Task.sleep(nanoseconds: 1_400_000_000)

        finishOnboarding()
    }

    private func flashGranted() async {
        stepGranted = true
        try? await Task.sleep(nanoseconds: 900_000_000)
        stepGranted = false
    }

    private func finishOnboarding() {
        isActive      = false
        isDemoActive  = false
        animController?.isOnboarding = false
        animController?.collapse()
        OnboardingService.shared.completeSetup()
        animController = nil
    }
}
