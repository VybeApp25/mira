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
    @Published private(set) var hudMode:       HUDMode    = .idle
    @Published private(set) var currentResult: AgentResult? = nil   // Fix 1: survives to .done view

    private let geometry: NotchGeometry
    private var hudResetTask: Task<Void, Never>?

    // Expanded target dimensions
    static let expandedW:  CGFloat = 700
    static let expandedH:  CGFloat = 252

    // Corner radius targets — top stays 0 so the panel reads as growing from the hardware notch.
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
        state = .expanded
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            self?.contentVisible = true
        }
    }

    func collapse() {
        guard state != .collapsed else { return }
        guard hudMode == .idle else { return }   // keep island open while agent is running
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
        // Ensure island is open so the HUD is visible
        if state != .expanded { expand() }
        HUDService.shared.startSession(projectName: projectName)
    }

    /// Call when an agent task finishes. Shows result + chips, then auto-returns to .idle.
    func endAgentRun(result: AgentResult, autoClearAfter seconds: TimeInterval = 8) {
        hudResetTask?.cancel()
        currentResult = result   // Fix 1: store the real result before switching to .done
        hudMode = .done
        HUDService.shared.endSession(result: result)
        ActionChipService.shared.show(from: result)

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
    }
}
