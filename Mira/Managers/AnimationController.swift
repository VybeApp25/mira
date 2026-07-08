import SwiftUI

// MARK: - Island state

enum IslandState: Equatable { case collapsed, expanded }

// MARK: - Controller

/// Drives all island animations. Views observe state + contentVisible to decide what to draw.
@MainActor
final class AnimationController: ObservableObject {

    @Published private(set) var state:          IslandState = .collapsed
    @Published private(set) var contentVisible: Bool        = false

    // Phase 2: HUD overlay mode — separate from IslandState so the
    // existing .collapsed/.expanded animation pair is never touched.
    @Published var isOnboarding:               Bool       = false
    @Published private(set) var hudMode:       HUDMode    = .idle
    @Published private(set) var currentResult: AgentResult? = nil   // Fix 1: survives to .done view

    private let geometry: NotchGeometry
    private var hudResetTask: Task<Void, Never>?

    // Expanded target dimensions
    static let expandedW:  CGFloat = 700
    static let expandedH:  CGFloat = 252
    // Content-dense tabs (settings, agents, crons) get a taller panel —
    // 252pt showed ~190pt of a 1400-line settings page through a scroll slot.
    static let expandedTallH: CGFloat = 420

    // Height of the currently displayed expanded panel. MiraIslandView keeps
    // this in sync with the active tab; NotchManager reads it for the hover
    // zone so a taller panel doesn't collapse when the cursor moves down into it.
    var currentExpandedH: CGFloat = AnimationController.expandedH

    // Corner radius targets — top stays 0 in both states so the panel reads as
    // growing FROM the hardware notch (Dynamic Island illusion). The expanded panel
    // keeps its top edge fused to the cutout; interactive content is seated below a
    // black notch-height band so the notch can't occlude a tab (see MiraIslandView).
    static let collapsedTopR:  CGFloat = 0
    static let collapsedBotR:  CGFloat = 10
    static let expandedTopR:   CGFloat = 0
    static let expandedBotR:   CGFloat = 20

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    // MARK: - Existing API (unchanged)

    func expand() {
        guard state != .expanded else { return }
        NSLog("[Mira] expand() called from:\n%@", Thread.callStackSymbols.prefix(10).joined(separator: "\n"))
        state = .expanded
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            self?.contentVisible = true
        }
    }

    func collapse() {
        guard state != .collapsed else { return }
        // Block only when the user needs to approve or answer — the collapsed pill
        // shows active state (thinking/speaking/listening) so there's no need to
        // keep the panel open just because processing is in flight.
        guard AgentJobStore.shared.confirmationPendingJobs.isEmpty else { return }
        guard AgentJobStore.shared.waitingForInputJobs.isEmpty else { return }
        contentVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            self?.state = .collapsed
        }
    }

    // MARK: - Phase 2: HUD control

    /// Call when an agent task begins. Expands the island and switches to HUD overlay.
    func beginAgentRun(projectName: String? = nil) {
        hudResetTask?.cancel()
        hudMode = .running
        if state != .expanded { expand() }
        HUDService.shared.startSession(projectName: projectName)
        AudioCueService.shared.playAgentLaunch()
    }

    /// Call when an agent task finishes. Shows result + chips, then auto-returns to .idle.
    func endAgentRun(result: AgentResult, autoClearAfter seconds: TimeInterval = 8) {
        hudResetTask?.cancel()
        currentResult = result
        hudMode = .done
        HUDService.shared.endSession(result: result)
        ActionChipService.shared.show(from: result)
        AudioCueService.shared.playAgentComplete()

        hudResetTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.2)) { self.hudMode = .idle }
                self.currentResult = nil
            }
        }
    }

    /// Manually clear the HUD overlay and return to normal tab content.
    func clearHUD() {
        hudResetTask?.cancel()
        ActionChipService.shared.hide()
        currentResult = nil
        withAnimation(.easeOut(duration: 0.2)) { hudMode = .idle }
    }

    /// Call when the agent is blocked and needs user input. Does not auto-clear.
    func blockAgentRun(reason: String) {
        hudResetTask?.cancel()
        hudMode = .blocked
        HUDService.shared.blockSession(reason: reason)
        AudioCueService.shared.playAgentBlocked()
    }
}
