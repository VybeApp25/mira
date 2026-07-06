import SwiftUI

// MARK: - Design tokens

private let accent   = DS.Colors.accent
private let positive = Color(red: 0.11, green: 0.73, blue: 0.33)
private let negative = Color(red: 1.0,  green: 0.27, blue: 0.23)
private let surface  = Color(red: 0.11, green: 0.11, blue: 0.14)

// MARK: - Root view

struct CursorCompanionView: View {
    let state:    CursorCompanionState
    @Binding var isPinned: Bool
    let onAction: (String) -> Void
    /// When true, the speech-bubble tail points left (bubble is right of cursor).
    /// When false, tail points right (bubble is left of cursor).
    var tailOnLeft: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch state {
            case .idle:
                Color.clear.frame(width: 1, height: 1)

            case .reply(let text):
                TypewriterReplyCard(text: text, isPinned: $isPinned,
                                    tailOnLeft: tailOnLeft, onAction: onAction)

            case .agentRunning(let title, let step, let current, let total, let progress):
                agentRunningCard(title: title, step: step,
                                 current: current, total: total, progress: progress)

            case .question(let text, let options, _):
                questionCard(text: text, options: options)

            case .confirmation(let summary, let actions):
                confirmationCard(summary: summary, actions: actions)

            case .success(let title, let actions):
                successCard(title: title, actions: actions)

            case .error(let message, _, let actions):
                errorCard(message: message, actions: actions)
            }
        }
        // Reply uses a defined 240pt width so the card fills its panel instead of
        // self-sizing narrow and getting centered (which left a big dead-space gap
        // between the cursor and the visible bubble). All other cards are 300pt.
        .frame(width: state.isReply ? 240 : 300)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Agent Running

    private func agentRunningCard(title: String, step: String,
                                   current: Int, total: Int, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                PulseDot(color: accent, reduceMotion: reduceMotion)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.90))
                    .lineLimit(1)
                Spacer(minLength: 0)
                pin
            }

            Text(step)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.50))
                .lineLimit(1)

            HStack(spacing: 8) {
                progressBar(value: progress, animated: !reduceMotion)
                if total > 0 {
                    Text("\(current)/\(total)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.30))
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(card)
    }

    // MARK: - Question

    private func questionCard(text: String, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.90))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)

            VStack(spacing: 5) {
                ForEach(options, id: \.self) { option in
                    Button { onAction("option:\(option)") } label: {
                        Text(option)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(accent.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(accent.opacity(0.30), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(card)
    }

    // MARK: - Confirmation

    private func confirmationCard(summary: String, actions: [CompanionActionSpec]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.80))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)

            if !actions.isEmpty {
                actionRow(actions)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(card)
    }

    // MARK: - Success

    private func successCard(title: String, actions: [CompanionActionSpec]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(positive)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer(minLength: 0)
                pin
            }
            if !actions.isEmpty { actionRow(actions) }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(card)
    }

    // MARK: - Error

    private func errorCard(message: String, actions: [CompanionActionSpec]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(negative)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
            if !actions.isEmpty { actionRow(actions) }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(card)
    }

    // MARK: - Shared components

    private var pin: some View {
        Button {
            isPinned.toggle()
            CursorCompanionTelemetry.shared.pinToggled(pinned: isPinned)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 9))
                .foregroundColor(isPinned ? accent : .white.opacity(0.20))
        }
        .buttonStyle(.plain)
    }

    private func actionRow(_ actions: [CompanionActionSpec]) -> some View {
        HStack(spacing: 6) {
            ForEach(actions) { spec in
                actionChip(spec)
            }
        }
    }

    private func actionChip(_ spec: CompanionActionSpec) -> some View {
        let (bg, fg): (Color, Color) = {
            switch spec.style {
            case .primary:     return (accent, .white)
            case .secondary:   return (Color.white.opacity(0.10), Color.white.opacity(0.80))
            case .destructive: return (negative.opacity(0.85), .white)
            }
        }()
        return Button { onAction(spec.tag) } label: {
            Text(spec.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(fg)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func progressBar(value: Double, animated: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.09))
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent.opacity(0.80))
                    .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
                    .animation(animated ? .spring(response: 0.5, dampingFraction: 0.85) : nil, value: value)
            }
        }
        .frame(height: 4)
    }

    private var card: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(surface.opacity(0.95))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
            // Speech bubble tail — points toward cursor
            GeometryReader { geo in
                let tailW: CGFloat = 8
                let tailH: CGFloat = 10
                let midY = geo.size.height / 2
                Path { p in
                    if tailOnLeft {
                        // Tail on left edge, pointing left
                        p.move(to: CGPoint(x: 0, y: midY - tailW / 2))
                        p.addLine(to: CGPoint(x: -tailH, y: midY))
                        p.addLine(to: CGPoint(x: 0, y: midY + tailW / 2))
                    } else {
                        // Tail on right edge, pointing right
                        p.move(to: CGPoint(x: geo.size.width, y: midY - tailW / 2))
                        p.addLine(to: CGPoint(x: geo.size.width + tailH, y: midY))
                        p.addLine(to: CGPoint(x: geo.size.width, y: midY + tailW / 2))
                    }
                }
                .fill(surface.opacity(0.95))
            }
        }
        .shadow(color: .black.opacity(0.40), radius: 18, x: 0, y: 6)
    }
}

// MARK: - TypewriterWaveformView
// Animated 3-bar waveform that pulses while the AI is generating a reply.
// Shows in place of the static Mira dot while typewriter reveal is in progress.

private struct TypewriterWaveformView: View {
    private static let speeds:  [Double] = [0.32, 0.26, 0.38]
    private static let offsets: [Double] = [0.00, 0.18, 0.09]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 1.5) {
                ForEach(0..<3, id: \.self) { i in
                    let amp = CGFloat((sin((t + Self.offsets[i]) / Self.speeds[i] * .pi * 2) + 1) / 2)
                    let h   = 3 + amp * 9
                    RoundedRectangle(cornerRadius: 1)
                        .fill(accent.opacity(0.88))
                        .frame(width: 2.5, height: h)
                }
            }
            .frame(height: 12)
        }
    }
}

// MARK: - Pulse dot

private struct PulseDot: View {
    let color:        Color
    let reduceMotion: Bool

    @State private var pulsing = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .fill(color.opacity(0.30))
                    .frame(width: 10, height: 10)
                    .scaleEffect(pulsing ? 1.7 : 1.0)
                    .opacity(pulsing ? 0 : 1)
                    .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulsing)
            }
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .onAppear { if !reduceMotion { pulsing = true } }
    }
}

// MARK: - Typewriter Reply Card

/// Full-width reply bubble with typewriter animation.
/// Reveals the complete response character-by-character next to the cursor.
private struct TypewriterReplyCard: View {
    let text: String
    @Binding var isPinned: Bool
    let tailOnLeft: Bool
    let onAction: (String) -> Void

    @State private var displayed = ""
    @State private var cursor    = true    // blinking cursor
    @State private var done      = false

    // ~40 chars/second feels natural for reading-speed reveal
    private let charsPerSecond: Double = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                // Mira dot — replaces with waveform while typewriting
                if !done {
                    TypewriterWaveformView()
                        .frame(width: 18)
                        .padding(.top, 3)
                } else {
                    Circle()
                        .fill(accent)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                }

                // Typewriter text + blinking cursor.
                // The cursor blinks via OPACITY on a constant-width block glyph — it is
                // ALWAYS laid out, just faded to 0 on the "off" beat. Swapping the glyph
                // for a narrow space (the old approach) changed the trailing width every
                // 0.5s, so at line-wrap boundaries the last word would wrap/unwrap on each
                // blink — which read as "weird spaces" jumping between the letters.
                (Text(displayed) + (done ? Text("")
                    : Text("▋").foregroundColor(accent.opacity(cursor ? 0.8 : 0.0))))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.92))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Pin button — top-right
                Button {
                    isPinned.toggle()
                    CursorCompanionTelemetry.shared.pinToggled(pinned: isPinned)
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 9))
                        .foregroundColor(isPinned ? accent : .white.opacity(0.20))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
        }
        .background(bubbleCard(tailOnLeft: tailOnLeft))
        .onAppear { startTypewriter() }
        .onChange(of: text) {
            displayed = ""
            done      = false
            startTypewriter()
        }
    }

    private func startTypewriter() {
        // Blinking cursor timer
        Task {
            while !done {
                try? await Task.sleep(nanoseconds: 500_000_000)
                cursor.toggle()
            }
        }

        // Character reveal loop
        Task {
            let chars = Array(text)
            let delay = UInt64(1_000_000_000 / charsPerSecond)
            for ch in chars {
                try? await Task.sleep(nanoseconds: delay)
                displayed.append(ch)
            }
            done = true
            cursor = false
        }
    }

    // Speech bubble card with tail
    private func bubbleCard(tailOnLeft: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(surface.opacity(0.97))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            GeometryReader { geo in
                let midY = geo.size.height / 2
                Path { p in
                    if tailOnLeft {
                        p.move(to: CGPoint(x: 0,         y: midY - 5))
                        p.addLine(to: CGPoint(x: -9,     y: midY))
                        p.addLine(to: CGPoint(x: 0,      y: midY + 5))
                    } else {
                        p.move(to: CGPoint(x: geo.size.width,     y: midY - 5))
                        p.addLine(to: CGPoint(x: geo.size.width + 9, y: midY))
                        p.addLine(to: CGPoint(x: geo.size.width,  y: midY + 5))
                    }
                }
                .fill(surface.opacity(0.97))
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 6)
    }
}
