// PromptComposer.swift
// Turns "I want a thing" into the prompt a coding agent should actually receive,
// using what is on screen, and hands it over.
//
// THIS IS THE GAP THE HEYCLICKY ADS DEMONSTRATE. Their pitch is not "we run an
// agent for you" — Claude Code already exists and is free. It is that the person
// who needs it says "I don't code", "I have never used Terminal", and "I'm
// scared of writing a bad prompt". What the tool actually contributes is the
// PROMPT: it looks at the screen, works out what the user is staring at, writes
// a careful brief with guardrails in it, and pastes that into the agent.
//
// So the value is not access to a model. It is:
//
//   1. CONTEXT THE USER DID NOT HAVE TO TYPE — the cinema, the film, the
//      showtime, the deck slide — read off the screen rather than asked for.
//   2. GUARDRAILS THE USER DID NOT KNOW TO ASK FOR. In the ad the composed
//      prompt says: explain in plain English before doing anything, ask before
//      changing files, keep everything inside one new folder, and never modify
//      anything outside it. A beginner does not know to write that, and it is
//      the difference between an agent that helps and one that edits their home
//      directory.
//   3. A HANDOFF, so they never touch the terminal.
//
// Mira already had every piece of this — screen capture, vision, a Claude Code
// driver, a Claude Desktop driver — and no path that put them together.
//
// WHAT THIS DELIBERATELY DOES NOT DO: send anything on its own. It composes and
// returns. The caller shows the user the prompt and lets them send it. An agent
// prompt written from a misread screen, submitted automatically, is a bad
// instruction executed with file access — and the user would never see the
// sentence that caused it.

import AppKit

@MainActor
final class PromptComposer: ObservableObject {

    static let shared = PromptComposer()

    enum Target {
        /// Claude Code in a terminal — the ad's case.
        case claudeCode
        /// The Claude Desktop app.
        case claudeDesktop

        var describedForModel: String {
            switch self {
            case .claudeCode:
                return "Claude Code, a command-line coding agent that can read, write and run files on this Mac"
            case .claudeDesktop:
                return "the Claude desktop app, which can discuss and produce text but has no direct access to this Mac's files"
            }
        }
    }

    struct Composed {
        let prompt: String
        /// What Mira thought it was looking at. Shown alongside the prompt so a
        /// misread is visible BEFORE the thing runs, not after.
        let understoodContext: String
    }

    private init() {}

    /// Compose a prompt for `intent`, informed by what is on screen.
    ///
    /// `skill` is optional extra expertise to apply — the ads' second video uses
    /// a Y Combinator skill written by a YC partner to judge a pitch line, which
    /// is the same shape as Mira's existing SkillCatalog entries.
    func compose(intent: String,
                 target: Target,
                 skill: String? = nil,
                 apiKey: String) async -> Composed? {
        let screenshot = await captureScreenJPEG()

        var instructions = """
        You are writing a PROMPT that a non-technical person will hand to \
        \(target.describedForModel). You are not answering their request \
        yourself — you are writing the brief.

        What they said they want:
        \(intent)

        Write the prompt as if THEY are speaking, in first person. It must:
        • state plainly that they are a non-technical beginner
        • say exactly what to build or do, using any specifics visible on screen
          (names, dates, venues, titles, the text they are editing)
        • ask the agent to explain in plain English BEFORE doing anything
        • ask it to check with them before changing or creating files
        • require everything to stay inside one new folder, and forbid modifying
          or deleting anything outside it
        • ask it to go one step at a time and to teach as it goes

        Those guardrails are not optional and not negotiable, even if the user \
        did not think to ask for them.
        """

        if let skill, !skill.isEmpty {
            instructions += "\n\nApply this expertise when writing the brief:\n\(skill)"
        }

        instructions += """


        Reply as JSON only, no prose around it:
        {"context": "<one sentence on what you can see they are working on>",
         "prompt": "<the prompt to hand over>"}
        """

        do {
            let raw: String
            if let screenshot {
                raw = try await ClaudeService(apiKey: apiKey).askStreaming(
                    prompt: instructions,
                    imageBase64: screenshot,
                    imageMediaType: "image/jpeg",
                    maxTokensOverride: 1400
                ) { _ in }
            } else {
                // No screen access is a degraded mode, not a failure — the
                // guardrails still matter, there is just less specificity.
                raw = try await ClaudeService(apiKey: apiKey)
                    .ask(prompt: instructions, maxTokensOverride: 1400)
            }
            return Self.parse(raw)
        } catch {
            return nil
        }
    }

    /// Hands a composed prompt to the target. Separate from `compose` on
    /// purpose: the user sees it first.
    @discardableResult
    func handOff(_ composed: Composed, to target: Target) async -> Bool {
        switch target {
        case .claudeDesktop:
            let result = await DesktopAppBridge.shared.send(composed.prompt,
                                                            to: .claude,
                                                            submit: false)
            return result == .wrote || result == .typed
        case .claudeCode:
            // Into the notch's own Claude Code session rather than a terminal
            // the user would have to find.
            RemoteControlService.shared.send(composed.prompt)
            return true
        }
    }

    // MARK: - Screen

    /// Downscaled JPEG of the main display, for the same reason as elsewhere: a
    /// full-resolution Retina PNG is ~14 MB base64 and over Anthropic's 5 MB
    /// per-image cap, which fails as an HTTP 400 rather than degrading.
    private func captureScreenJPEG() async -> String? {
        guard let image = try? await ScreenCaptureService().captureMainDisplay() else { return nil }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let maxDimension: CGFloat = 1600
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let scale = min(1, maxDimension / max(width, height))
        let size = NSSize(width: width * scale, height: height * scale)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])?
            .base64EncodedString()
    }

    // MARK: - Parsing

    /// Models wrap JSON in prose and fences however they feel. Take the outer
    /// braces and parse that; fall back to treating the whole reply as the
    /// prompt, since a usable prompt with no context line beats nothing.
    private static func parse(_ raw: String) -> Composed? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start < end,
           let data = String(trimmed[start...end]).data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let prompt = json["prompt"] as? String,
           !prompt.isEmpty {
            return Composed(prompt: prompt,
                            understoodContext: json["context"] as? String ?? "")
        }
        return trimmed.isEmpty ? nil : Composed(prompt: trimmed, understoodContext: "")
    }
}
