import AppKit

/// Receives dwell events from HoverDetectionService.
/// Captures a screenshot crop, asks Claude what's there, then:
///   - Plain dwell  → sets miraState.hoverSummary and expands the island (auto-clears after 5 s)
///   - ⌥-held dwell → shows a floating tooltip explanation (user-initiated, precise)
@MainActor
final class HoverInsightManager {

    private let miraState:      MiraState
    private let animController: AnimationController
    private let capture:        ScreenCaptureService
    private let tooltip:        HoverTooltipController
    private let history =       HoverHistoryStore.shared
    private let prefs   =       HoverPreferences.shared

    private var analysisTask: Task<Void, Never>?
    private var dismissTask:  Task<Void, Never>?

    private static let displaySeconds: TimeInterval = 5

    init(miraState: MiraState, animController: AnimationController,
         capture: ScreenCaptureService, tooltip: HoverTooltipController) {
        self.miraState      = miraState
        self.animController = animController
        self.capture        = capture
        self.tooltip        = tooltip
    }

    // MARK: - Entry point

    func handleDwell(at pos: CGPoint, optionHeld: Bool) {
        guard miraState.isSignedIn else { return }
        analysisTask?.cancel()
        analysisTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            do {
                let full = try await self.capture.captureMainDisplay()
                guard !Task.isCancelled else { return }
                let img    = self.crop(full, at: pos)
                let claude = ClaudeService(apiKey: self.miraState.effectiveAPIKey)
                let hint   = self.prefs.contextHint()

                if optionHeld {
                    await self.runExplain(claude: claude, image: img, pos: pos, hint: hint)
                } else {
                    await self.runSummary(claude: claude, image: img, pos: pos, hint: hint)
                }
            } catch {}
        }
    }

    /// Cancel any in-flight analysis and clear the summary from the island.
    func cancel() {
        analysisTask?.cancel()
        analysisTask = nil
        clearSummary()
    }

    // MARK: - Plain dwell → island summary bar

    private func runSummary(claude: ClaudeService, image: NSImage, pos: CGPoint, hint: String) async {
        let system = ["Return only a valid JSON object. Nothing else.", hint]
            .filter { !$0.isEmpty }.joined(separator: " ")

        let raw = (try? await claude.ask(
            prompt: """
            This is a tight crop centered on the user's cursor. Identify the single element directly under the cursor — not the surrounding layout.
            Return JSON only — no markdown:
            {"summary":"<1 sentence: what is this specific element>","interesting":<true if chart/code/error/data/image/product/text with real content, false if blank/nav/button/icon/empty space>,"category":"<code|financial|medical|gaming|data|product|error|other>"}
            """,
            screenshot: image,
            system: system
        )) ?? ""

        guard !Task.isCancelled, let result = parseSummary(raw), result.interesting else { return }

        let text = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        prefs.recordShown(category: result.category)
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName
        history.record(HoverEntry(text: text, reason: nil, appName: appName))

        showSummary(text)
    }

    // MARK: - ⌥-held → floating tooltip (user-initiated, stays as tooltip)

    private func runExplain(claude: ClaudeService, image: NSImage, pos: CGPoint, hint: String) async {
        tooltip.showLoading(near: pos)
        let system = [
            "You are a screen-aware assistant. Explain content specifically and concisely.",
            "Return only a valid JSON object — no markdown.",
            hint
        ].filter { !$0.isEmpty }.joined(separator: " ")

        let raw = (try? await claude.ask(
            prompt: """
            What is shown here and why might it matter? Under 25 words.
            Return JSON only: {"explanation":"<under 25 words>","category":"<code|financial|medical|gaming|data|product|error|other>"}
            """,
            screenshot: image,
            system: system
        )) ?? ""

        guard !Task.isCancelled, let result = parseExplain(raw) else { return }
        prefs.recordExplained(category: result.category)
        tooltip.show(text: result.explanation, near: pos, isExplanation: true)
    }

    // MARK: - Summary display lifecycle

    private func showSummary(_ text: String) {
        dismissTask?.cancel()
        miraState.hoverSummary = text

        // Expand the island if it is currently collapsed.
        if animController.state == .collapsed {
            animController.expand()
        }

        // Auto-clear after display duration.
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.displaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.clearSummary()
        }
    }

    private func clearSummary() {
        dismissTask?.cancel()
        dismissTask = nil
        miraState.hoverSummary = nil
    }

    // MARK: - JSON parsing

    private struct SummaryResponse: Decodable {
        let summary:     String
        let interesting: Bool
        let category:    String
    }

    private struct ExplainResponse: Decodable {
        let explanation: String
        let category:    String
    }

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

    // MARK: - Screenshot crop (200×150pt tight window around cursor)

    private func crop(_ image: NSImage, at screenPos: CGPoint) -> NSImage {
        guard let screen = NSScreen.main,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let sc = screen.backingScaleFactor
        let sh = screen.frame.height
        let ix = screenPos.x * sc
        let iy = (sh - screenPos.y) * sc
        let hw: CGFloat = 100 * sc
        let hh: CGFloat = 75 * sc
        let rx = max(0, ix - hw);  let ry = max(0, iy - hh)
        let rw = min(hw * 2, CGFloat(cg.width)  - rx)
        let rh = min(hh * 2, CGFloat(cg.height) - ry)
        guard rw > 0, rh > 0,
              let cropped = cg.cropping(to: CGRect(x: rx, y: ry, width: rw, height: rh)) else { return image }
        return NSImage(cgImage: cropped, size: CGSize(width: rw / sc, height: rh / sc))
    }
}
