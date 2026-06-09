import AppKit
import SwiftUI

// MARK: - CursorBubbleService
// Mirrors HeyClicky's CursorMessageBubbleView: a floating speech bubble that appears
// near the cursor during responses when the island is collapsed.
// Word-reveal animation matches HeyClicky's CursorMessageBubbleWordRevealModifier.

@MainActor
final class CursorBubbleService {
    static let shared = CursorBubbleService()
    private init() {}

    private var panel:      NSPanel?
    private var hideTask:   Task<Void, Never>?
    private var hostView:   NSHostingView<CursorBubbleRootView>?

    // MARK: - State passed into SwiftUI

    private var model = CursorBubbleModel()

    // MARK: - API

    /// Show the bubble at the current cursor position with streaming text.
    func showStreaming(at position: CGPoint? = nil) {
        model.words    = []
        model.isVisible = true
        setupPanelIfNeeded()
        let pt = position ?? currentCursorPosition()
        positionPanel(near: pt)
        guard let p = panel else { return }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1.0
        }
    }

    /// Append a token chunk to the bubble (word-by-word reveal).
    func append(token: String) {
        let newWords = token.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        for word in newWords {
            let w = CursorBubbleWord(text: word + " ")
            model.words.append(w)
        }
        hostView?.rootView = CursorBubbleRootView(model: model)
        resizePanelToFit()
    }

    /// Replace full text (for non-streaming use).
    func show(text: String, at position: CGPoint? = nil) {
        showStreaming(at: position)
        model.words = text
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { CursorBubbleWord(text: $0 + " ") }
        hostView?.rootView = CursorBubbleRootView(model: model)
        resizePanelToFit()
        scheduleAutoHide(after: 6.0)
    }

    func hide() {
        hideTask?.cancel()
        guard let p = panel else { return }
        model.isVisible = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        } completionHandler: {
            p.orderOut(nil)
        }
    }

    func finishStreaming() {
        scheduleAutoHide(after: 7.0)
    }

    // MARK: - Internals

    private func scheduleAutoHide(after seconds: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func setupPanelIfNeeded() {
        guard panel == nil else { return }
        let size = CGSize(width: 260, height: 72)
        let p = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        p.level              = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 5)
        p.backgroundColor    = .clear
        p.isOpaque           = false
        p.hasShadow          = false
        p.ignoresMouseEvents = true
        p.alphaValue         = 0
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let root = CursorBubbleRootView(model: model)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        p.contentView = host
        hostView = host
        panel = p
    }

    private func positionPanel(near cursor: CGPoint) {
        guard let p = panel else { return }
        // Offset: 18pt right, 20pt above cursor
        let x = cursor.x + 18
        let y = cursor.y + 20   // AppKit y=0 is bottom of screen
        let size = p.frame.size
        p.setFrameOrigin(CGPoint(x: x, y: y))
        _ = size
    }

    private func resizePanelToFit() {
        guard let p = panel else { return }
        // Clamp width; height grows with word count
        let wordCount = model.words.count
        let estimatedH = max(52, min(120, 36 + CGFloat(wordCount / 8) * 20))
        var f = p.frame
        f.size.height = estimatedH
        p.setFrame(f, display: true)
        if let hv = hostView { hv.frame = CGRect(origin: .zero, size: f.size) }
    }

    private func currentCursorPosition() -> CGPoint {
        // NSEvent gives screen coordinates (AppKit: y=0 at bottom)
        let loc = NSEvent.mouseLocation
        return loc
    }
}

// MARK: - Model + Word token (mirrors HeyClicky CursorMessageBubbleWordToken)

final class CursorBubbleModel: ObservableObject {
    @Published var words:     [CursorBubbleWord] = []
    @Published var isVisible: Bool = false
}

struct CursorBubbleWord: Identifiable {
    let id   = UUID()
    let text: String
}

// MARK: - Root SwiftUI view

struct CursorBubbleRootView: View {
    @ObservedObject var model: CursorBubbleModel

    var body: some View {
        CursorMessageBubbleView(words: model.words)
            .frame(maxWidth: 244)
    }
}

// MARK: - CursorMessageBubbleView (mirrors HeyClicky's CursorMessageBubbleView)

struct CursorMessageBubbleView: View {
    let words: [CursorBubbleWord]

    private let bubbleBg     = Color(red: 0.12, green: 0.12, blue: 0.17)
    private let borderColor  = Color.white.opacity(0.12)
    private let miraTeale    = Color(red: 0.20, green: 0.85, blue: 0.75)

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Callout tail
            TailShape()
                .fill(bubbleBg)
                .frame(width: 12, height: 8)
                .offset(x: 14, y: 7)

            // Bubble body
            flowText
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(bubbleBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(borderColor, lineWidth: 0.5)
                        )
                )
                .shadow(color: .black.opacity(0.30), radius: 8, x: 0, y: 3)
                .offset(y: 0)
        }
        .padding(.leading, 2)
        .padding(.bottom, 8)
    }

    // Word-by-word flow (mirrors CursorMessageBubbleWordRevealModifier)
    private var flowText: some View {
        FlowLayout(spacing: 3) {
            ForEach(Array(words.enumerated()), id: \.element.id) { idx, word in
                Text(word.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .animation(
                        .spring(response: 0.22, dampingFraction: 0.70)
                            .delay(Double(idx % 6) * 0.018),
                        value: words.count
                    )
            }
        }
        .frame(maxWidth: 220, alignment: .leading)
    }
}

// MARK: - Callout tail shape

private struct TailShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: 0))
        p.addLine(to: CGPoint(x: rect.width / 2, y: rect.height))
        p.closeSubpath()
        return p
    }
}

// MARK: - FlowLayout (wrapping HStack)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 220
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, totalH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxW && x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            rowH = max(rowH, s.height); x += s.width + spacing
        }
        totalH = y + rowH
        return CGSize(width: maxW, height: totalH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            rowH = max(rowH, s.height); x += s.width + spacing
        }
    }
}
