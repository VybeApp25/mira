// CollapsedMediaEarsView.swift
// Media presentation for the CLOSED notch, in the ears rather than below it.
//
// The first version put a small icon and a line of text in the drop strip under
// the cutout. That is the wrong place: MacNotch uses the EARS — the empty
// menu-bar space either side of the camera cutout — with album art on the left
// and a moving waveform on the right. Content beside the notch reads as part of
// the hardware; content hanging below it reads as a banner the app is showing you.
//
// Three things this fixes at once:
//   • Position — art left, waveform right, both at menu-bar height.
//   • Proportion — the pill spans art + cutout + waveform, so it is wide and
//     shallow instead of tall with a dangling strip.
//   • Track change — MacNotch widens briefly to show what just started, then
//     settles back to the compact form. `TrackChangeMonitor` drives that here.
//
// Typography note: the title is the only text, at 11pt medium. The artist is
// dropped in the compact form on purpose — two lines of metadata in a 30pt strip
// is what made the first attempt feel cramped.

import SwiftUI
import AppKit

// MARK: - Artwork colour

/// Pulls a vivid accent out of album artwork so the waveform is tinted by what's
/// playing rather than being a flat white. MacNotch does this — with a yellow
/// album its bars are gold — and it's most of why their collapsed media reads as
/// designed rather than generic.
///
/// Cached by artwork identity: this runs on the main actor and the waveform
/// redraws 30x a second, so recomputing per frame would be absurd.
@MainActor
enum ArtworkAccent {

    private static var cache: [ObjectIdentifier: Color] = [:]
    private static let fallback = Color.white.opacity(0.80)

    static func color(for image: NSImage?) -> Color {
        guard let image else { return fallback }
        let key = ObjectIdentifier(image)
        if let hit = cache[key] { return hit }

        let result = compute(image) ?? fallback
        // Bounded so a long session with many tracks can't grow without limit.
        if cache.count > 32 { cache.removeAll() }
        cache[key] = result
        return result
    }

    /// Averages the most saturated pixels of a downsampled copy. Weighting by
    /// saturation avoids the washed-out grey you get from averaging everything,
    /// which is what makes naive dominant-colour extraction look muddy.
    private static func compute(_ image: NSImage) -> Color? {
        let side = 16
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var rSum = 0.0, gSum = 0.0, bSum = 0.0, wSum = 0.0
        for y in 0..<side {
            for x in 0..<side {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
                let maxC = max(r, g, b), minC = min(r, g, b)
                let sat = maxC <= 0 ? 0 : (maxC - minC) / maxC
                // Ignore near-black and near-white; they carry no hue.
                guard maxC > 0.18, minC < 0.96 else { continue }
                let w = sat * sat * maxC
                rSum += r * w; gSum += g * w; bSum += b * w; wSum += w
            }
        }
        guard wSum > 0.001 else { return nil }

        // Lift toward full brightness so the bars stay legible on black.
        var r = rSum / wSum, g = gSum / wSum, b = bSum / wSum
        let peak = max(r, g, b)
        if peak > 0 {
            let lift = min(1.0 / peak, 1.6)
            r *= lift; g *= lift; b *= lift
        }
        return Color(red: min(r, 1), green: min(g, 1), blue: min(b, 1))
    }
}

// MARK: - Track-change detection

/// Publishes a brief "just changed" window so the pill can widen and name the
/// new track, then settle. Watches title+artist rather than any elapsed-time
/// field, so a normal position tick never counts as a change.
@MainActor
final class TrackChangeMonitor: ObservableObject {

    static let shared = TrackChangeMonitor()

    /// True for `expandedWindow` seconds after a new track starts.
    @Published private(set) var justChanged = false

    /// MEASURED from MacNotch at 60fps: its widen begins at t=250ms and the
    /// collapse begins at t=3050ms, so the pill holds wide for ~2.8s before
    /// returning. Was 3.5s by guess.
    private static let expandedWindow: TimeInterval = 2.8

    /// MEASURED from the same capture. MacNotch's widen overshoots and settles:
    /// 532 -> peak 884 at 283ms -> settles to 841 by 800ms. That is a 13.9%
    /// overshoot, which solves to a damping ratio of 0.53; a 283ms time-to-peak
    /// gives omega_n ~= 13.1 rad/s, i.e. a SwiftUI `response` of ~0.48. The
    /// collapse mirrors it (489 trough against a 529 rest, ~13% undershoot).
    ///
    /// Mira previously used response 0.36 / damping 0.80 — stiffer, and with no
    /// perceptible bounce at all. The bounce is the character of the motion.
    static let widenSpring = Animation.spring(response: 0.48, dampingFraction: 0.53)
    static let settleSpring = Animation.spring(response: 0.46, dampingFraction: 0.55)
    private var lastKey = ""
    private var resetWork: DispatchWorkItem?

    private init() {}

    /// Called from the view as Now Playing updates.
    func note(title: String, artist: String) {
        let key = "\(title)|\(artist)"
        guard key != lastKey else { return }
        let hadPrevious = !lastKey.isEmpty
        lastKey = key
        guard hadPrevious, !title.isEmpty else { return }   // don't fire on first load

        resetWork?.cancel()
        withAnimation(Self.widenSpring) { justChanged = true }

        let work = DispatchWorkItem { [weak self] in
            withAnimation(Self.settleSpring) { self?.justChanged = false }
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.expandedWindow, execute: work)
    }
}

// MARK: - View

struct CollapsedMediaEarsView: View {

    @ObservedObject private var nowPlaying = NowPlayingService.shared
    @ObservedObject private var trackChange = TrackChangeMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width of the hardware (or synthesised) cutout to leave clear between ears.
    let notchWidth: CGFloat

    private var info: NowPlayingInfo { nowPlaying.info }

    var body: some View {
        HStack(spacing: 0) {
            leftEar
            // The cutout itself — nothing may be drawn here, the camera occludes it.
            Color.clear.frame(width: notchWidth)
            rightEar
        }
        .onChange(of: info.title) { _, _ in
            trackChange.note(title: info.title, artist: info.artist)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(info.artist.isEmpty
                            ? "Playing \(info.title)"
                            : "Playing \(info.title) by \(info.artist)")
    }

    // MARK: - Left ear: artwork (+ title while a track change is fresh)

    private var leftEar: some View {
        HStack(spacing: 7) {
            artwork
            if trackChange.justChanged {
                // Title ONLY, truncated. MacNotch's widened form shows a single
                // line at a substantial weight — no artist row. Stacking two
                // lines of metadata into a ~30pt strip is what made the earlier
                // version feel cramped, and their capture confirms they don't.
                Text(info.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
    }

    @ViewBuilder
    private var artwork: some View {
        if let art = info.artwork {
            Image(nsImage: art)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                )
        } else {
            // Placeholder keeps the ear's width stable while artwork loads, so
            // the pill doesn't jitter a moment after a track starts.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.10))
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                )
        }
    }

    // MARK: - Right ear: waveform

    private var rightEar: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            MediaWaveform(isPlaying: info.isPlaying,
                          reduceMotion: reduceMotion,
                          tint: ArtworkAccent.color(for: info.artwork))
                .frame(width: 30, height: 17)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 12)
    }
}

// MARK: - Waveform

/// Five bars on staggered sine phases. Deliberately not an FFT of the audio —
/// Mira has no tap on system audio output here, and a plausible motion at 30fps
/// is what the eye reads as "playing" anyway. Freezes flat when paused, which is
/// the one thing it must get honestly right.
private struct MediaWaveform: View {

    let isPlaying: Bool
    let reduceMotion: Bool
    /// Taken from the album artwork, so the bars carry the record's colour.
    let tint: Color

    // Seven thin bars rather than five thick ones — denser reads as a level
    // meter, sparser reads as a loading indicator.
    private static let bars = 7
    private static let phases: [Double] = [0.0, 0.9, 1.8, 0.45, 1.35, 2.2, 0.7]
    private static let speeds: [Double] = [3.1, 2.4, 3.6, 2.8, 3.3, 2.6, 3.9]

    var body: some View {
        if reduceMotion || !isPlaying {
            staticBars
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                bars { i in
                    let s = sin(t * Self.speeds[i] + Self.phases[i])
                    return 0.30 + 0.70 * (s * s)   // sin² keeps it positive and lively
                }
            }
        }
    }

    private var staticBars: some View {
        bars { _ in 0.28 }
    }

    private func bars(_ height: @escaping (Int) -> Double) -> some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(0..<Self.bars, id: \.self) { i in
                Capsule()
                    .fill(tint)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .scaleEffect(y: height(i), anchor: .center)
            }
        }
    }
}
