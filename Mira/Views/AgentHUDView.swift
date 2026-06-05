// AgentHUDView.swift
// Phase 2 — Radio-dispatch live update stream shown while an agent is running.
//
// Design contract (from the architecture doc):
// • One sentence per update, active voice
// • Milestone-based: "Analyzing VoiceManager.swift." not "Looking at file 3 of 47."
// • Light walkie-talkie feel — brisk, confident

import SwiftUI

struct AgentHUDView: View {
    @ObservedObject var hud: HUDService

    // Accent matches the island's blue
    private let accent = Color(red: 0.29, green: 0.62, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.07))
            messageStream
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: - Header row

    private var header: some View {
        HStack(spacing: 8) {
            // Pulsing dot — indicates live agent activity
            PulsingDot()

            Text(hud.activeProjectName.map { "Working on \($0)" } ?? "Mira is working")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))

            Spacer()

            Text("LIVE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(accent.opacity(0.6))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Message stream (last 5 updates, newest at bottom)

    private var messageStream: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(hud.updates.suffix(5)) { update in
                        HUDMessageRow(update: update, isCurrent: update.id == hud.updates.last?.id)
                            .id(update.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: hud.updates.count) { _ in
                if let last = hud.updates.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Single message row

private struct HUDMessageRow: View {
    let update: HUDUpdate
    let isCurrent: Bool

    private let accent = Color(red: 0.29, green: 0.62, blue: 1.0)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: update.category.icon)
                .font(.system(size: 9))
                .foregroundColor(isCurrent ? accent : .white.opacity(0.18))
                .frame(width: 12)

            Text(update.message)
                .font(.system(size: 12))
                .foregroundColor(isCurrent ? .white.opacity(0.92) : .white.opacity(0.28))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
    }
}

// MARK: - Pulsing activity dot

private struct PulsingDot: View {
    @State private var pulsing = false
    private let accent = Color(red: 0.29, green: 0.62, blue: 1.0)

    var body: some View {
        Circle()
            .fill(accent)
            .frame(width: 6, height: 6)
            .scaleEffect(pulsing ? 1.4 : 1.0)
            .opacity(pulsing ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                       value: pulsing)
            .onAppear { pulsing = true }
    }
}
