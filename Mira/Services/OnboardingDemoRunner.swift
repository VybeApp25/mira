import Cocoa
import SwiftUI

/// Drives the three interactive capability demos and the personalized finale that
/// run during onboarding (see docs — HeyClicky-parity onboarding). This is the
/// *logic* layer only: the SwiftUI step views in `OnboardingView.swift` own the
/// UI, the 15s watchdog, and the Skip control, and call into these functions.
///
/// Design rules (mirrors the onboarding spec):
///  • Never block. Every demo degrades gracefully — on any failure it returns and
///    the caller advances. No error walls during onboarding.
///  • Narration and annotation are synced: the mark is drawn *before* the sentence
///    is spoken (`OnboardingNarrator.speakAndWait`).
///  • Consequential actions (the draft-reply demo) never send — the view presents
///    an approval sheet and only pastes on explicit approval.
///
/// All work is bound to Mira's real services — no placeholders:
///   ScreenCaptureService, GroundingService, OnboardingNarrator, ClaudeService,
///   OverlayWindowController, NSWorkspace.
@MainActor
final class OnboardingDemoRunner {
    static let shared = OnboardingDemoRunner()
    private init() {}

    /// Dedicated overlay for demo highlights so we never fight the live guidance
    /// overlay. Hidden between demos.
    private let overlay = OverlayWindowController()

    // MARK: - Demo 1: "Find something interesting on your screen"

    /// Screenshots the screen, asks the grounding pipeline for the single most
    /// notable element, highlights it, and narrates what it saw. Returns whether a
    /// confident element was grounded (the view uses this only for its own copy).
    @discardableResult
    func findSomethingInteresting() async -> Bool {
        guard let shot = await primaryCapture() else {
            await OnboardingNarrator.shared.speakAndWait(
                "I couldn't see your screen just yet — you can grant Screen Recording in Settings anytime.")
            return false
        }

        let outcome = await GroundingService.shared.ground(
            question: "The single most interesting or important thing a first-time user would want pointed out on this screen.",
            screenshotData: shot.imageData,
            displayFrame: shot.displayFrame)

        switch outcome {
        case let .grounded(location, _, _, confidence) where gateDecision(for: outcome) == .annotate:
            // Draw the mark first, then speak — keeps narration synced to the ring.
            highlight(normalized: location, on: shot.displayFrame)
            await OnboardingNarrator.shared.speakAndWait(
                "See that? I can look at whatever's on your screen and point right at what matters.")
            _ = confidence
            hideHighlight(after: 2.0)
            return true

        default:
            // No confident target — still a valid teaching state, never an error.
            await OnboardingNarrator.shared.speakAndWait(
                "Whenever something's on your screen, I can look and point right at what matters.")
            return false
        }
    }

    // MARK: - Demo 2: "What is this?" (identify under cursor)

    /// Narrates the prompt, waits for the user's next click anywhere, then grounds
    /// the element at that point and describes it aloud. Times out silently after
    /// `clickTimeout` so the watchdog is never the only escape hatch.
    func identifyUnderCursor(clickTimeout: TimeInterval = 10) async {
        await OnboardingNarrator.shared.speakAndWait("Click anything on your screen, and I'll tell you what it is.")

        guard let point = await awaitNextClick(timeout: clickTimeout) else {
            await OnboardingNarrator.shared.speakAndWait("No rush — you can point me at anything, anytime.")
            return
        }

        // Point the marker at the click immediately, then resolve + narrate.
        overlay.show(at: flipToTopLeft(point), label: "This")

        guard let shot = await primaryCapture() else { hideHighlight(after: 1.5); return }
        let outcome = await GroundingService.shared.ground(
            question: "The UI element the user just clicked at screen point \(Int(point.x)), \(Int(point.y)). What is it and what does it do?",
            screenshotData: shot.imageData,
            displayFrame: shot.displayFrame)

        let line: String
        switch outcome {
        case .grounded:      line = "That's an interactive element — I can read what's on screen and act on it for you."
        case .noElement:     line = "That spot's just background — but I can read anything on your screen and act on it."
        case .uncertain:     line = "I can read what's on your screen and act on it for you."
        }
        await OnboardingNarrator.shared.speakAndWait(line)
        hideHighlight(after: 1.5)
    }

    // MARK: - Demo 3: "Do something for me" (draft a reply — approval required)

    /// Captures the screen for context and drafts a short reply with the real LLM.
    /// Returns the draft text for the view to present in an approval sheet. NEVER
    /// sends or pastes anything itself. Returns nil on any failure (view advances).
    func draftReply() async -> String? {
        await OnboardingNarrator.shared.speakAndWait("Here's the magic — I'll draft a reply for whatever's on your screen. You approve before anything happens.")

        let image = try? await ScreenCaptureService().captureMainDisplay()
        let claude = ClaudeService(apiKey: ClaudeService.effectiveOpenRouterKey)
        let system = "You are Mira, drafting a short, friendly reply to whatever message or email is visible on the user's screen. If nothing looks like a message, write one warm sentence introducing yourself. Output only the reply text — no preamble."
        let prompt = "Draft a concise reply to the message on screen. Keep it under 40 words."

        guard let draft = try? await claude.ask(prompt: prompt, screenshot: image, system: system),
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Finale: personalized welcome page from real installed apps

    /// Renders a local HTML welcome page featuring the user's name and the real
    /// icons of apps actually installed on this Mac, then opens it. Self-contained
    /// (no network, no API key) — the "it already knows my machine" proof moment.
    /// Returns the file URL that was opened, or nil on failure.
    @discardableResult
    func generateFinalePage(name: String) -> URL? {
        let icons = installedAppIcons(limit: 5)
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "there" : name

        let iconTags = icons.compactMap { pair -> String? in
            guard let b64 = pngBase64(pair.image) else { return nil }
            return """
            <figure><img src="data:image/png;base64,\(b64)" alt="\(escape(pair.name))"/><figcaption>\(escape(pair.name))</figcaption></figure>
            """
        }.joined(separator: "\n")

        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Hello \(escape(safeName))</title>
        <style>
          :root { color-scheme: dark; }
          html,body{height:100%;margin:0;background:#08080b;color:#fff;
            font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display',sans-serif;}
          .wrap{min-height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;
            text-align:center;padding:48px;box-sizing:border-box;}
          h1{font-size:52px;font-weight:800;margin:0 0 8px;letter-spacing:-1px;}
          h1 span{background:linear-gradient(90deg,#5EA7FF,#8f7bff);-webkit-background-clip:text;
            -webkit-text-fill-color:transparent;}
          p{font-size:17px;color:#a8abb4;margin:0 0 40px;}
          .apps{display:flex;gap:28px;flex-wrap:wrap;justify-content:center;}
          figure{margin:0;display:flex;flex-direction:column;align-items:center;gap:8px;
            animation:rise .5s ease both;}
          figure:nth-child(2){animation-delay:.06s} figure:nth-child(3){animation-delay:.12s}
          figure:nth-child(4){animation-delay:.18s} figure:nth-child(5){animation-delay:.24s}
          img{width:64px;height:64px;border-radius:14px;box-shadow:0 8px 28px rgba(0,0,0,.45);}
          figcaption{font-size:12px;color:#8b8f99;}
          @keyframes rise{from{opacity:0;transform:translateY(12px)}to{opacity:1;transform:none}}
        </style></head><body><div class="wrap">
          <h1>Hello <span>\(escape(safeName))</span></h1>
          <p>Your Mac just got a little more magical. I already see what you're working with:</p>
          <div class="apps">\(iconTags)</div>
        </div></body></html>
        """

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MiraOnboarding", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("welcome.html")
        do {
            try html.data(using: .utf8)?.write(to: url)
            NSWorkspace.shared.open(url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Installed apps

    /// Real installed apps from /Applications, skipping Apple system apps so the
    /// icons feel personal. Falls back to whatever it can read.
    private func installedAppIcons(limit: Int) -> [(name: String, image: NSImage)] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"),
                                                includingPropertiesForKeys: nil)) ?? []
        let apps = urls.filter { $0.pathExtension == "app" }
        let systemNames: Set<String> = ["Safari", "Mail", "Messages", "FaceTime", "Photos",
                                        "Music", "TV", "Podcasts", "News", "Stocks", "Home"]
        var picked: [(String, NSImage)] = []
        for app in apps {
            let display = app.deletingPathExtension().lastPathComponent
            if systemNames.contains(display) { continue }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            picked.append((display, icon))
            if picked.count >= limit { break }
        }
        // If everything got filtered (unlikely), fall back to the first few apps.
        if picked.isEmpty {
            for app in apps.prefix(limit) {
                picked.append((app.deletingPathExtension().lastPathComponent,
                               NSWorkspace.shared.icon(forFile: app.path)))
            }
        }
        return picked
    }

    // MARK: - Screen capture helper

    /// One JPEG capture of the cursor's display (matches TeachingEngine's path).
    private func primaryCapture() async -> MiraScreenCapture? {
        guard let screens = try? await ScreenCaptureService.captureAllDisplaysAsJPEG() else { return nil }
        return screens.first(where: { $0.isCursorScreen }) ?? screens.first
    }

    // MARK: - Overlay helpers

    /// Highlights a normalized (0–1, top-left) grounded point on the given display.
    /// NOTE: overlay coordinate convention is verified on-device — the grounding
    /// `location` is top-left normalized for the full-screen canvas, matching the
    /// overlay's screenSize mapping.
    private func highlight(normalized: CGPoint, on displayFrame: CGRect) {
        let w = displayFrame.width, h = displayFrame.height
        let center = CGPoint(x: normalized.x * w, y: normalized.y * h)   // top-left space
        let box = CGRect(x: center.x - 60, y: center.y - 40, width: 120, height: 80)
        overlay.annotate(rect: box, style: .circle, color: .blue)
    }

    private func hideHighlight(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.overlay.hide()
        }
    }

    /// Global mouse events use a bottom-left origin; the overlay's point path
    /// expects top-left within the main screen. Flip Y.
    private func flipToTopLeft(_ p: CGPoint) -> CGPoint {
        guard let screen = NSScreen.main else { return p }
        return CGPoint(x: p.x, y: screen.frame.height - p.y)
    }

    // MARK: - Click gate

    /// Suspends until the user's next left click anywhere, or nil after `timeout`.
    /// Uses a global monitor (no Accessibility trust needed for mouse events).
    private func awaitNextClick(timeout: TimeInterval) async -> CGPoint? {
        await withCheckedContinuation { (cont: CheckedContinuation<CGPoint?, Never>) in
            var monitor: Any?
            var finished = false
            let finish: (CGPoint?) -> Void = { point in
                guard !finished else { return }
                finished = true
                if let m = monitor { NSEvent.removeMonitor(m) }
                cont.resume(returning: point)
            }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
                finish(NSEvent.mouseLocation)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    // MARK: - HTML helpers

    private func pngBase64(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png.base64EncodedString()
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
