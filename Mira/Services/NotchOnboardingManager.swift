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
        case welcome, signIn, microphone, screenRecording, accessibility, done
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
        await narrator.speakAndWait("Hey — I'm Mira. I live right here in your notch, always ready to help. Let me get you set up in about a minute.")
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }

        // Sign in
        if !AccountService.shared.isSignedIn {
            step = .signIn
            animController?.currentExpandedH = 420
            await narrator.speakAndWait("First, let's get you signed in so I can power up for you.")
            while !AccountService.shared.isSignedIn && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else { return }
            animController?.currentExpandedH = 270
            await narrator.speakAndWait("Perfect. You're in.")
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
        await narrator.speakAndWait("You're all set. Voice, screen guidance, and chat are ready to go. And depending on the plan you subscribe to, I can do a whole lot more — run agents in the background, connect your apps, and handle tasks for you. I'm right here whenever you need me.")
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
