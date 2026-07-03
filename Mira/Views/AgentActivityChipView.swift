import SwiftUI

// MARK: - AgentActivityChipView
//
// A compact, purely-informational floating chip for a live AgentActivity.
// Reuses the liquidGlass surface + spinner from FloatingAgentChipView so it
// reads as the same system. Deliberately has NO gestures / buttons — that keeps
// it click-through (background, non-intrusive) while a computer-use run works.

struct AgentActivityChipView: View {
    let activity: AgentActivity

    private var accent: Color { activity.status.color }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                glyphTile

                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)

                    if !activity.subtitle.isEmpty {
                        Text(activity.subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.48))
                            .lineLimit(1)
                            .transition(.opacity)
                            .id(activity.subtitle)   // crossfade on text change
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                statusChip
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Thin progress line at the bottom edge (active work only)
            if activity.status.isActive {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Color.white.opacity(0.06)
                        accent.opacity(0.75)
                            .frame(width: geo.size.width * CGFloat(activity.progress))
                            .animation(.spring(response: 0.6, dampingFraction: 0.9),
                                       value: activity.progress)
                    }
                }
                .frame(height: 2)
            }
        }
        .frame(width: 260)
        .liquidGlass(cornerRadius: 15, tiltDegrees: 0, glowColor: accent)
        .animation(.easeInOut(duration: 0.22), value: activity.subtitle)
    }

    // MARK: - Sub-components

    private var glyphTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(accent.opacity(0.15))
                .frame(width: 32, height: 32)

            if activity.status.isActive {
                BlueCursorSpinnerPublic(color: accent).frame(width: 16, height: 16)
            } else {
                Image(systemName: activity.status.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accent)
            }
        }
    }

    private var statusChip: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(accent)
                .frame(width: 5, height: 5)
                .opacity(activity.status.isActive ? 1 : 0.6)

            Text(activity.status.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(accent)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(activity.status.isTerminal ? 0.12 : 0.18))
        )
    }
}
