// AgentResultView.swift
// Phase 2 — Result summary + action chips shown when hudMode == .done.
//
// Shows a one-sentence plain-text summary (no markdown), then the chip row.
// Matches HeyClicky's "floating bubble" UX adapted for the notch island.

import SwiftUI

struct AgentResultView: View {
    let result: AgentResult
    @ObservedObject var chipService: ActionChipService
    var onChipTapped: (String) -> Void = { _ in }

    private let accent   = DS.Colors.accent
    private let successG = Color(red: 0.20, green: 0.84, blue: 0.60)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow
            if chipService.isVisible {
                Divider().background(Color.white.opacity(0.07))
                ActionChipsView(chipService: chipService, onChipTapped: onChipTapped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
    }

    // MARK: - Summary row

    private var summaryRow: some View {
        HStack(alignment: .top, spacing: 10) {
            // Success check with soft glow
            ZStack {
                Circle()
                    .fill(successG.opacity(0.14))
                    .frame(width: 26, height: 26)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(successG)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(result.doneTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))

                Text(result.summary)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, chipService.isVisible ? 8 : 14)
    }
}
