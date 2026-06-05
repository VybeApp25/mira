import AppKit
import Foundation

// MARK: - Event

enum HoverEvent {
    /// Interesting content identified. Carries summary text, optional reason ("why you're seeing this"), and position.
    case summary(String, String?, CGPoint)
    /// ⌥-held dwell fired; loading state should appear immediately.
    case explainStart(CGPoint)
    /// Richer explanation ready (⌥-held path). Category is recorded automatically.
    case explain(String, CGPoint)
}

// MARK: - Service

/// Polls cursor position every 100 ms.
/// After a 3-second stable dwell:
///   - Plain hover  → Claude returns {summary, interesting, category}; shows only if interesting=true.
///   - ⌥ held       → fires explainStart immediately, then fetches a richer explanation.
/// Engagement (shown / explained) is recorded to HoverPreferences so the interesting
/// threshold adapts per content category over time.
@MainActor
final class HoverSummaryService {

    var onEvent: ((HoverEvent) -> Void)?
    /// Set false while the Mira island is expanded or a voice session is active.
    var isEnabled = true

    private var timer: Timer?
    private var dwellOrigin: CGPoint = .zero
    private var dwellStart:  Date    = .distantPast
    private var lastFetchOrigin: CGPoint = CGPoint(x: -9999, y: -9999)
    private var isFetching = false

    private let capture: ScreenCaptureService
    private let prefs = HoverPreferences.shared
    private let apiKey: () -> String

    private struct SummaryResponse: Decodable {
        let summary:     String
        let interesting: Bool
        let category:    String
        let reason:      String?
    }

    private struct ExplainResponse: Decodable {
        let explanation: String
        let category:    String
    }

    init(apiKey: @escaping () -> String) {
        self.apiKey  = apiKey
        self.capture = ScreenCaptureService()
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isFetching = false
    }

    // MARK: - Private

    private func tick() {
        guard isEnabled, prefs.screenCompanionEnabled, !isFetching else { return }
        let pos = NSEvent.mouseLocation

        if dist(pos, dwellOrigin) > 20 {
            dwellOrigin = pos
            dwellStart  = Date()
            return
        }

        guard Date().timeIntervalSince(dwellStart) >= prefs.sensitivity.dwellSeconds,
              dist(pos, lastFetchOrigin) > 80 else { return }

        fetch(at: pos, explain: NSEvent.modifierFlags.contains(.option))
    }

    private func fetch(at pos: CGPoint, explain: Bool) {
        isFetching = true
        lastFetchOrigin = pos
        let key = apiKey()
        guard !key.isEmpty else { isFetching = false; return }

        if explain { onEvent?(.explainStart(pos)) }

        let hint = prefs.contextHint()

        Task {
            defer { Task { @MainActor in self.isFetching = false } }
            do {
                let full   = try await capture.captureMainDisplay()
                let img    = crop(full, at: pos) ?? full
                let claude = ClaudeService(apiKey: key)

                if explain {
                    let systemPrompt = [
                        "You are a screen-aware assistant. Explain content specifically and concisely.",
                        "Return only a valid JSON object — no markdown.",
                        hint
                    ].filter { !$0.isEmpty }.joined(separator: " ")

                    let raw = try await claude.ask(
                        prompt: """
                        What is shown and why might it matter to the user? Under 25 words, no preamble.
                        Return JSON only: {"explanation":"<under 25 words>","category":"<code|financial|medical|gaming|data|product|error|other>"}
                        """,
                        screenshot: img,
                        system: systemPrompt
                    )
                    guard let result = parseExplain(raw), !result.explanation.isEmpty else { return }
                    await MainActor.run {
                        self.prefs.recordExplained(category: result.category)
                        self.onEvent?(.explain(result.explanation, pos))
                    }

                } else {
                    let systemPrompt = [
                        "Return only a valid JSON object. Nothing else.",
                        hint
                    ].filter { !$0.isEmpty }.joined(separator: " ")

                    let raw = try await claude.ask(
                        prompt: """
                        Look at this screenshot. Return JSON only — no markdown:
                        {"summary":"<5 words max>","interesting":<true if chart/error/code/data/diagram/product/medical/financial, false if navigation/button/icon/empty space/generic UI>,"category":"<code|financial|medical|gaming|data|product|error|other>","reason":"<8 words max why this is worth noticing, or omit if not interesting>"}
                        """,
                        screenshot: img,
                        system: systemPrompt
                    )
                    guard let result = parseSummary(raw), result.interesting else { return }
                    let text = String(result.summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                    guard !text.isEmpty else { return }
                    let reason = result.reason.flatMap { r in
                        let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? nil : String(t.prefix(80))
                    }
                    await MainActor.run {
                        self.prefs.recordShown(category: result.category)
                        self.onEvent?(.summary(text, reason, pos))
                    }
                }
            } catch {}
        }
    }

    // MARK: - JSON parsing (tolerates backticks / extra whitespace)

    private func parseSummary(_ raw: String) -> SummaryResponse? {
        extractJSON(raw).flatMap { try? JSONDecoder().decode(SummaryResponse.self, from: $0) }
    }

    private func parseExplain(_ raw: String) -> ExplainResponse? {
        extractJSON(raw).flatMap { try? JSONDecoder().decode(ExplainResponse.self, from: $0) }
    }

    private func extractJSON(_ raw: String) -> Data? {
        guard let lo = raw.range(of: "{"),
              let hi = raw.range(of: "}", options: .backwards) else { return nil }
        return String(raw[lo.lowerBound...hi.upperBound]).data(using: .utf8)
    }

    // MARK: - Screenshot crop

    private func crop(_ image: NSImage, at screenPos: CGPoint) -> NSImage? {
        guard let screen = NSScreen.main,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let sc = screen.backingScaleFactor
        let sh = screen.frame.height
        // Cocoa: y=0 at bottom → image: y=0 at top
        let ix = screenPos.x * sc
        let iy = (sh - screenPos.y) * sc
        let hw: CGFloat = 250 * sc
        let hh: CGFloat = 175 * sc
        let rx = max(0, ix - hw)
        let ry = max(0, iy - hh)
        let rw = min(hw * 2, CGFloat(cg.width)  - rx)
        let rh = min(hh * 2, CGFloat(cg.height) - ry)
        guard rw > 0, rh > 0,
              let cropped = cg.cropping(to: CGRect(x: rx, y: ry, width: rw, height: rh)) else { return nil }
        return NSImage(cgImage: cropped, size: CGSize(width: rw / sc, height: rh / sc))
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
    }
}
