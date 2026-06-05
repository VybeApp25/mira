// ActionChipsView.swift
// Phase 2 — Row of 1–3 tappable next-action chips shown after task completion.
//
// Chips auto-dismiss after 8s (managed by ActionChipService).
// Tapping fires the chip's .prompt as the next user message.

import SwiftUI

struct ActionChipsView: View {
    @ObservedObject var chipService: ActionChipService

    // Callback to route chip taps into the chat / agent
    var onChipTapped: (String) -> Void = { _ in }

    var body: some View {
        if chipService.isVisible && !chipService.chips.isEmpty {
            HStack(spacing: 8) {
                ForEach(chipService.chips) { chip in
                    ChipButton(chip: chip) {
                        chipService.tapped(chip)
                        onChipTapped(chip.prompt)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

// MARK: - Single chip

private struct ChipButton: View {
    let chip: ProjectNextAction
    let action: () -> Void

    @State private var pressed = false

    private let accent = Color(red: 0.29, green: 0.62, blue: 1.0)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: chip.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(chip.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(.white.opacity(0.90))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(pressed ? 0.14 : 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
            )
            .scaleEffect(pressed ? 0.95 : 1.0)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true  } }
                .onEnded   { _ in withAnimation(.easeOut(duration: 0.12)) { pressed = false } }
        )
    }
}
