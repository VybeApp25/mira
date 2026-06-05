// ActionChipService.swift
// Phase 2 — Manages tappable action chips shown after an agent task completes.
//
// Chips are self-contained: tapping one sends its .prompt directly as the
// next user message. No user input needed for any chip.
//
// Design contract:
// • Max 3 chips (Mira shows 1 fewer than HeyClicky for a cleaner notch)
// • Label ≤ 35 characters
// • Each chip must be fully executable with zero additional user input
// • Auto-dismiss after 8 seconds if untapped
// • Dismiss immediately on tap

import Foundation
import SwiftUI

@MainActor
final class ActionChipService: ObservableObject {

    static let shared = ActionChipService()

    // MARK: - Published state

    @Published private(set) var chips:     [ProjectNextAction] = []
    @Published private(set) var isVisible: Bool                = false

    // MARK: - Private

    private var dismissTask: Task<Void, Never>?
    private var clearTask:   Task<Void, Never>?   // tracks the delayed chips = [] after hide()
    private var onPromptSelected: ((String) -> Void)?

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Show chips with optional auto-dismiss. Pass a handler to receive the
    /// selected prompt so the caller can route it to the chat/agent.
    func show(_ actions: [ProjectNextAction],
              autoDismissAfter seconds: TimeInterval = 8,
              onSelect: ((String) -> Void)? = nil) {
        dismissTask?.cancel()
        clearTask?.cancel()   // cancel any in-flight chips = [] from a prior hide()
        // Enforce max 3, trim labels to 35 chars
        chips = Array(actions.prefix(3)).map { action in
            var a = action
            if a.label.count > 35 { a.label = String(a.label.prefix(32)) + "…" }
            return a
        }
        onPromptSelected = onSelect
        isVisible = !chips.isEmpty

        // Auto-dismiss
        if seconds > 0 && !chips.isEmpty {
            dismissTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if !Task.isCancelled { self.hide() }
            }
        }
    }

    /// User tapped a chip — fire the prompt and dismiss.
    func tapped(_ action: ProjectNextAction) {
        dismissTask?.cancel()
        hide()
        onPromptSelected?(action.prompt)
    }

    func hide() {
        dismissTask?.cancel()
        clearTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            isVisible = false
        }
        clearTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !Task.isCancelled { self.chips = [] }
        }
    }

    /// Convenience: build a standard set of chips from an AgentResult.
    func show(from result: AgentResult, onSelect: ((String) -> Void)? = nil) {
        show(result.nextActions, onSelect: onSelect)
    }
}
