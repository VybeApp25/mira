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
        let narrator = OnboardingNarrator.shared
        let svc      = OnboardingService.shared

        // Welcome
        step = .welcome
        await narrator.speakAndWait("Hey — I'm Mira. I live right here in your Mac's notch, always one hold away. I'm the AI that actually does things — not just answers questions. Let me show you what I mean.")
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }

        // Demo: Voice
        step = .voice
        await narrator.speakAndWait("My voice is always on. Hold Control-Option anywhere on your Mac and I wake up instantly, ready to listen. Ask me to write an email, summarise what's on your screen, set a reminder, look something up — I'll answer and act. No switching apps, no typing, no waiting.")
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }

        // Demo: Screen Guidance
        step = .screenGuidance
        await narrator.speakAndWait("I can see exactly what you're looking at too. Hold Control-Option-V and draw on your screen to show me anything — a button you can't find, a form that's confusing, a chart you want explained. I'll point to the exact thing and walk you through it step by step, in any app.")
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }

        // Demo: Autonomy
        step = .autonomy
        await narrator.speakAndWait("Here's where I'm different from every other assistant. I can actually take over your Mac and do things for you. Fill out a form. Click through a settings screen. Navigate a complex workflow. You describe the task, I execute it — you watch it happen in real time, or go grab a coffee while I handle it.")
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }

        // Demo: Agents
        step = .agents
        await narrator.speakAndWait("And for bigger projects, I run background agents. Ask me to build a landing page, research competitors, process a batch of files, or connect your tools. I'll spin up an agent, work in the background, and report back when it's done. I'm always working, even when you're not watching.")
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }

        // Sign in
        if !AccountService.shared.isSignedIn {
            step = .signIn
            animController?.currentExpandedH = 420
            await narrator.speakAndWait("Alright — let's get you set up. First, sign in or create your account. I handle all the AI keys behind the scenes, so you never have to manage them yourself.")
            while !AccountService.shared.isSignedIn && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else { return }
            animController?.currentExpandedH = 270
            await narrator.speakAndWait("Perfect. You're in. Let's get my permissions sorted so I can actually do all of that.")
        } else {
            await narrator.speakAndWait("Alright — let's finish getting me set up so I can do all of that for you.")
        }
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
        isActive = false
        animController?.isOnboarding = false
        animController?.collapse()
        OnboardingService.shared.completeSetup()
        animController = nil
    }
}
