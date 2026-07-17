import AppKit
import SwiftUI

// MARK: - CursorBubbleService
// Thin facade over OverlayWindowManager. Callers (IslandChatView etc.) keep
// the same API; the actual bubble lives inside the full-screen overlay window.

@MainActor
final class CursorBubbleService {
    static let shared = CursorBubbleService()
    private init() {}

    func showStreaming(at position: CGPoint? = nil) {
        OverlayWindowManager.shared.showBubble()
    }

    func append(token: String) {
        OverlayWindowManager.shared.appendBubbleToken(token)
    }

    func show(text: String, at position: CGPoint? = nil) {
        OverlayWindowManager.shared.showBubble()
        for word in text.components(separatedBy: .whitespaces).filter({ !$0.isEmpty }) {
            OverlayWindowManager.shared.appendBubbleToken(word + " ")
        }
        OverlayWindowManager.shared.finishBubble()
    }

    func finishStreaming() {
        OverlayWindowManager.shared.finishBubble()
    }

    func hide() {
        OverlayWindowManager.shared.hideBubble()
    }
}

// MARK: - CursorMessageBubbleView
// Matches HeyClicky's CursorMessageBubbleView: compact dark card with a callout
// tail and word-by-word spring reveal (CursorMessageBubbleWordRevealModifier).

struct CursorMessageBubbleView: View {
    let words: [BubbleWordToken]
    var tailOnLeft: Bool = true

    private let bg     = Color(red: 0.09, green: 0.09, blue: 0.13)
    private let border = Color.white.opacity(0.10)

    var body: some View {
        ZStack(alignment: tailOnLeft ? .bottomLeading : .bottomTrailing) {
            // Callout tail
            BubbleTailShape(pointsLeft: tailOnLeft)
                .fill(bg)
                .frame(width: 10, height: 7)
                .offset(x: tailOnLeft ? 14 : -14, y: 6)

            // Bubble body
            wordFlow
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(bg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(border, lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
                )
        }
        .frame(maxWidth: 260)
        .fixedSize(horizontal: false, vertical: true)
    }

    // Word-by-word flow layout with spring reveal
    // (CursorMessageBubbleWordRevealModifier + CursorMessageBubbleWordToken)
    private var wordFlow: some View {
        BubbleFlowLayout(spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.element.id) { idx, token in
                Text(token.text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .fixedSize()
                    .scaleEffect(1.0)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.72).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
                    .animation(
                        .spring(response: 0.20, dampingFraction: 0.65)
                            .delay(Double(idx % 8) * 0.016),
                        value: words.count
                    )
            }
        }
        .frame(maxWidth: 236, alignment: .leading)
    }
}

// MARK: - Callout tail

private struct BubbleTailShape: Shape {
    let pointsLeft: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if pointsLeft {
            // Triangle pointing left (toward cursor)
            p.move(to: CGPoint(x: rect.maxX, y: 0))
            p.addLine(to: CGPoint(x: 0,         y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            // Triangle pointing right (cursor is to the right)
            p.move(to: CGPoint(x: 0,        y: 0))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: 0,         y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Word-wrap flow layout (BubbleFlowLayout)

private struct BubbleFlowLayout: Layout {
    var spacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 236
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxW && x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            rowH = max(rowH, s.height)
            x += s.width + spacing
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX {
                y += rowH + spacing; x = bounds.minX; rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            rowH = max(rowH, s.height)
            x += s.width + spacing
        }
    }
}
