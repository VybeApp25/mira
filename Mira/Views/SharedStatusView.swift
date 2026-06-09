import SwiftUI

// MARK: - Mira's distinct palette

let miraTeale  = Color(red: 0.05, green: 0.80, blue: 0.75)   // aurora teal  #0DCCC0
let miraViolet = Color(red: 0.62, green: 0.50, blue: 0.92)   // soft violet  #9E80EB

// MARK: - SharedStatusView
//
// Always-mounted status subview that persists across collapsed ↔ expanded transitions.
// Driven by PillStateModel; uses absolute-time animation so animations never reset
// regardless of when the view is first rendered or how many times the pill resizes.
//
// Visualizations:
//   idle     — spark glyph, barely visible
//   thinking — 3-dot breathing constellation (violet → teal)
//   working  — 4-dot left-to-right pulse (violet)
//   speaking — 7-bar reed waveform (teal)

struct SharedStatusView: View {
    @ObservedObject var pillState: PillStateModel
    /// true = collapsed pill (compact), false = expanded (slightly larger)
    var isCompact: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            indicator(t: t)
        }
        .animation(.easeInOut(duration: 0.14), value: pillState.mode)
        .accessibilityLabel(pillState.mode.accessibilityLabel)
        .accessibilityHidden(false)
    }

    @ViewBuilder
    private func indicator(t: Double) -> some View {
        switch pillState.mode {
        case .idle:
            sparkGlyph
                .transition(.opacity.combined(with: .scale(scale: 0.70)))
        case .thinking:
            constellation(t: t)
                .transition(.opacity.combined(with: .scale(scale: 0.80)))
        case .working:
            workingPulse(t: t)
                .transition(.opacity.combined(with: .scale(scale: 0.80)))
        case .speaking:
            reedWaveform(t: t)
                .transition(.opacity.combined(with: .scale(scale: 0.80)))
        }
    }

    // MARK: - Idle: spark glyph

    private var sparkGlyph: some View {
        Image(systemName: "sparkle")
            .font(.system(size: isCompact ? 9 : 11, weight: .light))
            .foregroundColor(miraTeale.opacity(0.28))
    }

    // MARK: - Thinking: breathing constellation

    // 3 dots in a subtle equilateral triangle.
    // Each dot breathes (scale + opacity) on a 900 ms cycle, staggered 300 ms apart.
    private func constellation(t: Double) -> some View {
        let size: CGFloat = isCompact ? 13 : 17
        let r: CGFloat    = size * 0.38   // radius from center to each dot center
        let cx            = size / 2
        let cy            = size / 2

        // Dot positions: top, bottom-left, bottom-right (rotated 90° from standard triangle)
        let positions: [(x: CGFloat, y: CGFloat)] = [
            (cx + r * CGFloat(cos(-CGFloat.pi / 2)),       cy + r * CGFloat(sin(-CGFloat.pi / 2))),
            (cx + r * CGFloat(cos(-CGFloat.pi / 2 + 2.094)), cy + r * CGFloat(sin(-CGFloat.pi / 2 + 2.094))),
            (cx + r * CGFloat(cos(-CGFloat.pi / 2 + 4.189)), cy + r * CGFloat(sin(-CGFloat.pi / 2 + 4.189))),
        ]

        return ZStack {
            ForEach(0..<3, id: \.self) { i in
                let phase  = CGFloat((sin((t + Double(i) * 0.30) / 0.90 * .pi * 2) + 1) / 2)
                let scale: CGFloat = reduceMotion ? 1.0 : 0.55 + phase * 0.60
                let opacity        = reduceMotion ? 0.75 : 0.30 + phase * 0.65
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [miraViolet, miraTeale],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: isCompact ? 3.5 : 4.5,
                           height: isCompact ? 3.5 : 4.5)
                    .scaleEffect(scale)
                    .opacity(opacity)
                    .position(x: positions[i].x, y: positions[i].y)
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Working: left-to-right pulse

    // 4 dots sweeping left → right on a 900 ms period.
    private func workingPulse(t: Double) -> some View {
        HStack(spacing: isCompact ? 3 : 4) {
            ForEach(0..<4, id: \.self) { i in
                let phase  = CGFloat((sin((t - Double(i) * 0.225) / 0.90 * .pi * 2) + 1) / 2)
                let sz: CGFloat = reduceMotion
                    ? (isCompact ? 3.5 : 4.5)
                    : (isCompact ? 2.5 + phase * 2.0 : 3.0 + phase * 2.5)
                Circle()
                    .fill(miraViolet.opacity(reduceMotion ? 0.75 : 0.28 + phase * 0.68))
                    .frame(width: sz, height: sz)
            }
        }
    }

    // MARK: - Speaking: reed waveform

    // 7 rounded bars with organic heights driven by absolute time.
    // Each bar has a unique speed and phase offset so the shape looks alive.
    private static let reedSpeeds:  [Double] = [0.28, 0.35, 0.26, 0.40, 0.31, 0.38, 0.29]
    private static let reedOffsets: [Double] = [0.00, 0.18, 0.37, 0.55, 0.12, 0.44, 0.27]

    private func reedWaveform(t: Double) -> some View {
        let barW: CGFloat  = isCompact ? 2.0 : 2.5
        let maxH: CGFloat  = isCompact ? 14  : 18
        let minH: CGFloat  = 3

        return HStack(spacing: isCompact ? 1.5 : 2) {
            ForEach(0..<7, id: \.self) { i in
                let amp = CGFloat((sin((t + Self.reedOffsets[i]) / Self.reedSpeeds[i] * .pi * 2) + 1) / 2)
                let h   = reduceMotion ? maxH * 0.55 : minH + amp * (maxH - minH)
                RoundedRectangle(cornerRadius: 1)
                    .fill(miraTeale.opacity(0.88))
                    .frame(width: barW, height: h)
            }
        }
        .frame(height: maxH)
    }
}
