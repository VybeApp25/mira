import Foundation

// MARK: - Website Builder Agent

enum WebsiteBuilderAgent {

    /// Entry point. Pass `userProvidedInfo` when resuming after a waitingForInput state.
    static func run(jobId: UUID, prompt: String, apiKey: String, store: AgentJobStore, userProvidedInfo: String? = nil) async {
        let claude = ClaudeService(apiKey: apiKey)

        // PHASE 1: Requirements analysis (skipped on resume — we trust the user's answers)
        if userProvidedInfo == nil {
            await store.updateStep(id: jobId, stepTitle: "Analyzing requirements", progress: 0.08, stepIndex: 0)

            let readiness = await analyzeRequirements(prompt: prompt, claude: claude)
            await store.appendLog(id: jobId, stepIndex: 0, message: "Score: \(Int(readiness.score))% — \(readiness.summary)")

            if readiness.shouldAsk {
                // Not enough information — pause and surface the requirements card
                await store.markWaitingForInput(id: jobId, readiness: readiness)
                return
            }

            // 70–89: proceed but we'll note assumptions in the generation prompt
            if readiness.hasWarnings {
                await store.appendLog(id: jobId, stepIndex: 0, message: "Building with assumptions: \(readiness.assumptions.joined(separator: ", "))")
            }
        }

        // PHASE 2: Build the website

        // Build the enriched prompt
        var enrichedPrompt = prompt
        if let extra = userProvidedInfo, !extra.isEmpty {
            enrichedPrompt += "\n\nAdditional context provided by user:\n\(extra)"
        }

        // Step 1: Structure
        await store.updateStep(id: jobId, stepTitle: "Generating structure", progress: 0.20, stepIndex: 1)

        let structurePrompt = """
        The user wants to build a website. Their request: "\(enrichedPrompt)"

        In 2-3 sentences, describe:
        1. The site name and purpose
        2. The target audience
        3. The 4-6 main sections (e.g. Hero, About, Services, Testimonials, Pricing, Contact)

        Be specific and concrete. No markdown.
        """

        let structure: String
        do {
            structure = try await claude.ask(prompt: structurePrompt,
                                             system: "You are a professional web architect. Be precise and brief.",
                                             modelOverride: "claude-haiku-4-5-20251001")
        } catch {
            await store.failJob(id: jobId, error: "Failed to plan structure: \(error.localizedDescription)")
            return
        }
        await store.appendLog(id: jobId, stepIndex: 1, message: structure)

        // Step 2: Design tokens
        await store.updateStep(id: jobId, stepTitle: "Creating design", progress: 0.35, stepIndex: 2)
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Step 3: Write code
        await store.updateStep(id: jobId, stepTitle: "Writing code", progress: 0.50, stepIndex: 3)

        let codePrompt = """
        Build a complete, stunning, modern single-file website for the following:

        REQUEST: "\(enrichedPrompt)"

        SITE PLAN: \(structure)

        REQUIREMENTS — follow every rule below exactly:
        - Output ONLY valid HTML5. Nothing else. No explanation. No markdown code fences.
        - Start with <!DOCTYPE html> and end with </html>
        - Embed ALL CSS in a <style> tag inside <head>
        - Use a bold, dark design: deep black/navy backgrounds (#0a0a0f or similar), vibrant accent color matching the brand, white text
        - Include these sections: Hero (with headline, subheadline, CTA button), Features/About (3-column grid), Social proof or stats bar, Contact/Footer
        - Typography: -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif
        - Mobile-responsive using CSS Grid and Flexbox; add @media (max-width: 768px)
        - Smooth scroll, hover effects on buttons/cards, subtle gradient backgrounds
        - hero section must have min-height: 100vh and center content vertically
        - CTA buttons must have real styling: gradient background, padding, border-radius, hover transform
        - NO external CDN links. NO placeholder images (use CSS gradient backgrounds instead)
        - Body must have background-color set, never transparent or white
        - All text must be visible — check contrast against background colors
        - Include real placeholder content that matches the business (no Lorem Ipsum)

        Output the complete HTML file. Start immediately with <!DOCTYPE html>.
        """

        let htmlCode: String
        do {
            htmlCode = try await claude.ask(prompt: codePrompt,
                                            system: "You are an expert web developer. Output only clean, production-ready HTML. Never output anything other than the HTML file.",
                                            modelOverride: "claude-sonnet-4-6",
                                            maxTokensOverride: 6000)
        } catch {
            await store.failJob(id: jobId, error: "Failed to generate website: \(error.localizedDescription)")
            return
        }

        // Step 4: Validate
        await store.updateStep(id: jobId, stepTitle: "Validating output", progress: 0.72, stepIndex: 4)

        // Strip any accidental markdown fences Claude might output
        let cleaned = stripMarkdownFences(htmlCode)

        guard cleaned.contains("<!DOCTYPE") || cleaned.contains("<html") else {
            await store.failJob(id: jobId, error: "Output was not valid HTML. Please try again with more detail.")
            return
        }

        // Step 5: Await approval before writing any files
        let siteName = extractSiteName(from: enrichedPrompt)
        let lineCount = cleaned.components(separatedBy: "\n").count
        let outputDir = websiteDirectory(for: jobId)

        await store.updateStep(id: jobId, stepTitle: "Awaiting approval", progress: 0.80, stepIndex: 5)

        let confirmRequest = ConfirmationRequest(
            title: "Save website to disk?",
            summary: "Mira will write \(lineCount) lines of HTML to:\n\(outputDir.appendingPathComponent("index.html").path)",
            riskLevel: .low,
            approveLabel: "Save Website",
            denyLabel: "Discard"
        )
        let approved = await store.requestConfirmation(id: jobId, request: confirmRequest)
        guard approved else { return }  // denyConfirmation already set status to .cancelled

        // Step 6: Write files (user approved)
        await store.markWriting(id: jobId)
        await store.updateStep(id: jobId, stepTitle: "Saving project", progress: 0.88, stepIndex: 6)

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let indexURL = outputDir.appendingPathComponent("index.html")
            try cleaned.write(to: indexURL, atomically: true, encoding: .utf8)
        } catch {
            await store.failJob(id: jobId, error: "Failed to save website: \(error.localizedDescription)")
            return
        }

        // Finish project record
        await store.updateStep(id: jobId, stepTitle: "Saving project", progress: 0.96, stepIndex: 6)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let outputPath = outputDir.appendingPathComponent("index.html").path

        let result = AgentJobResult(
            summary: "Built \(siteName) — \(lineCount) lines of code.",
            outputPath: outputPath,
            previewImagePath: nil,
            metadata: [
                "siteName": siteName,
                "outputDirectory": outputDir.path,
                "linesOfCode": "\(lineCount)",
            ]
        )
        await store.completeJob(id: jobId, result: result)
    }

    // MARK: - Requirements Analysis

    /// Calls Claude to score how much context we have. Returns a BuildReadiness score.
    static func analyzeRequirements(prompt: String, claude: ClaudeService) async -> BuildReadiness {
        let analysisPrompt = """
        Analyze this website build request. Determine if there is enough information to generate a high-quality, non-generic website.

        REQUEST: "\(prompt)"

        Score criteria:
        - 90-100: Have specific business name, description, audience, visual style, and content
        - 70-89: Have most details, can make reasonable assumptions for the rest
        - 40-69: Missing 2+ critical pieces (what the business does, who it's for, what content it needs)
        - 0-39: Extremely vague — would produce a generic template with no real value

        Missing requirements to ask about (only include what's actually missing):
        - Business/product description (what does it do?)
        - Target audience (who is it for?)
        - Pages or sections needed
        - Visual style or color palette
        - Call-to-action or main goal
        - Any logo or assets available

        Respond ONLY with valid JSON, no commentary, no markdown fences:
        {
          "score": <integer 0-100>,
          "missingRequirements": ["<specific question 1>", "<specific question 2>"],
          "assumptions": ["<assumption if we were to proceed>"],
          "summary": "<one sentence assessment>"
        }
        """

        do {
            let raw = try await claude.ask(
                prompt: analysisPrompt,
                system: "You are a requirements analyst. Output only JSON. No explanation.",
                modelOverride: "claude-haiku-4-5-20251001",
                maxTokensOverride: 500
            )
            return parseReadiness(from: raw) ?? defaultReadiness(for: prompt)
        } catch {
            // If analysis fails, be conservative — ask rather than generate garbage
            return BuildReadiness(
                score: 50,
                missingRequirements: [
                    "What does your business or project do?",
                    "Who are your target customers?",
                    "What style or colors should the site use?",
                    "What is the main action you want visitors to take?",
                ],
                assumptions: [],
                summary: "Could not analyze requirements — providing questions to ensure quality output."
            )
        }
    }

    /// Parse JSON response from Claude into BuildReadiness. Returns nil if parse fails.
    private static func parseReadiness(from text: String) -> BuildReadiness? {
        // Extract JSON object from the text (Claude sometimes adds a sentence before/after)
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        let jsonStr = String(text[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let score  = (obj["score"] as? Double) ?? (obj["score"] as? Int).map { Double($0) } ?? 50
        let missing = obj["missingRequirements"] as? [String] ?? []
        let assume  = obj["assumptions"] as? [String] ?? []
        let summary = obj["summary"] as? String ?? "Analysis complete."

        return BuildReadiness(score: score, missingRequirements: missing, assumptions: assume, summary: summary)
    }

    /// Fallback readiness when JSON parse fails — score based on prompt length as heuristic.
    private static func defaultReadiness(for prompt: String) -> BuildReadiness {
        let words = prompt.split(separator: " ").count
        let score: Double = words > 15 ? 75 : (words > 8 ? 60 : 35)
        return BuildReadiness(
            score: score,
            missingRequirements: score < 70 ? [
                "What does your business or project do?",
                "Who are your target customers?",
                "What pages do you need?",
                "What visual style do you prefer?",
            ] : [],
            assumptions: score >= 70 ? ["Using a modern dark design theme", "Marketing/landing page format"] : [],
            summary: words > 15 ? "Sufficient detail to proceed." : "More context needed for a quality result."
        )
    }

    // MARK: - Helpers

    private static func stripMarkdownFences(_ html: String) -> String {
        var result = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```html") { result = String(result.dropFirst(7)) }
        else if result.hasPrefix("```") { result = String(result.dropFirst(3)) }
        if result.hasSuffix("```") { result = String(result.dropLast(3)) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func websiteDirectory(for jobId: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Mira/Projects/Websites/\(jobId.uuidString)", isDirectory: true)
    }

    private static func extractSiteName(from prompt: String) -> String {
        let words = prompt.components(separatedBy: " ")
        if let forIdx = words.firstIndex(of: "for") ?? words.firstIndex(of: "FOR"), forIdx + 1 < words.count {
            let name = words[(forIdx + 1)...].prefix(3).joined(separator: " ")
                .trimmingCharacters(in: .punctuationCharacters)
            if !name.isEmpty { return name }
        }
        return words.prefix(4).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Research Agent

enum ResearchAgent {
    static func run(jobId: UUID, prompt: String, apiKey: String, store: AgentJobStore) async {
        let claude = ClaudeService(apiKey: apiKey)

        await store.updateStep(id: jobId, stepTitle: "Defining research scope", progress: 0.10, stepIndex: 0)
        try? await Task.sleep(nanoseconds: 400_000_000)
        await store.updateStep(id: jobId, stepTitle: "Gathering information", progress: 0.25, stepIndex: 1)

        let researchPrompt = """
        Conduct thorough research on: "\(prompt)"

        Format as a structured report:
        # Executive Summary
        (2-3 sentences)

        # Key Findings
        - (5-7 bullet points)

        # Detailed Analysis
        (3-4 paragraphs)

        # Recommendations
        1. (3-5 actionable items)

        # Conclusion
        (2-3 sentences)
        """

        await store.updateStep(id: jobId, stepTitle: "Analyzing findings", progress: 0.45, stepIndex: 2)

        let report: String
        do {
            report = try await claude.ask(prompt: researchPrompt,
                                          system: "You are a senior research analyst. Produce thorough, well-structured reports.",
                                          modelOverride: "claude-sonnet-4-6",
                                          maxTokensOverride: 3000)
        } catch {
            await store.failJob(id: jobId, error: "Research failed: \(error.localizedDescription)")
            return
        }

        await store.updateStep(id: jobId, stepTitle: "Synthesizing insights", progress: 0.65, stepIndex: 3)
        try? await Task.sleep(nanoseconds: 300_000_000)
        await store.updateStep(id: jobId, stepTitle: "Writing report", progress: 0.80, stepIndex: 4)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mira/Projects/Research/\(jobId.uuidString)", isDirectory: true)
        let fileURL = dir.appendingPathComponent("report.md")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try report.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            await store.failJob(id: jobId, error: "Failed to save report: \(error.localizedDescription)")
            return
        }

        await store.updateStep(id: jobId, stepTitle: "Saving report", progress: 0.95, stepIndex: 5)
        let firstLine = report.components(separatedBy: "\n").first(where: { $0.contains("#") }) ?? "Research complete."
        await store.completeJob(id: jobId, result: AgentJobResult(
            summary: firstLine.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces),
            outputPath: fileURL.path, previewImagePath: nil, metadata: [:]
        ))
    }
}

// MARK: - Content Agent

enum ContentAgent {
    static func run(jobId: UUID, prompt: String, apiKey: String, store: AgentJobStore) async {
        let claude = ClaudeService(apiKey: apiKey)

        await store.updateStep(id: jobId, stepTitle: "Understanding brief", progress: 0.10, stepIndex: 0)
        try? await Task.sleep(nanoseconds: 300_000_000)
        await store.updateStep(id: jobId, stepTitle: "Generating outline", progress: 0.25, stepIndex: 1)
        try? await Task.sleep(nanoseconds: 300_000_000)
        await store.updateStep(id: jobId, stepTitle: "Writing content", progress: 0.45, stepIndex: 2)

        let content: String
        do {
            content = try await claude.ask(
                prompt: prompt,
                system: "You are a professional content writer. Produce polished, engaging content tailored to the request.",
                modelOverride: "claude-sonnet-4-6",
                maxTokensOverride: 2000
            )
        } catch {
            await store.failJob(id: jobId, error: "Content generation failed: \(error.localizedDescription)")
            return
        }

        await store.updateStep(id: jobId, stepTitle: "Refining draft", progress: 0.80, stepIndex: 3)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mira/Projects/Documents/\(jobId.uuidString)", isDirectory: true)
        let fileURL = dir.appendingPathComponent("content.md")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            await store.failJob(id: jobId, error: "Failed to save content: \(error.localizedDescription)")
            return
        }

        await store.updateStep(id: jobId, stepTitle: "Saving file", progress: 0.95, stepIndex: 4)
        let firstLine = content.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Content ready."
        await store.completeJob(id: jobId, result: AgentJobResult(
            summary: firstLine, outputPath: fileURL.path, previewImagePath: nil,
            metadata: ["wordCount": "\(content.components(separatedBy: " ").count)"]
        ))
    }
}

// MARK: - Generic Agent (fallback)

enum GenericAgent {
    static func run(jobId: UUID, prompt: String, apiKey: String, store: AgentJobStore) async {
        let claude = ClaudeService(apiKey: apiKey)
        await store.updateStep(id: jobId, stepTitle: "Processing request", progress: 0.20, stepIndex: 0)

        let reply: String
        do {
            reply = try await claude.ask(prompt: prompt,
                                         system: "You are Mira, a capable AI assistant. Complete the user's request thoroughly.",
                                         maxTokensOverride: 800)
        } catch {
            await store.failJob(id: jobId, error: error.localizedDescription)
            return
        }

        await store.updateStep(id: jobId, stepTitle: "Generating result", progress: 0.70, stepIndex: 1)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await store.updateStep(id: jobId, stepTitle: "Saving output", progress: 0.95, stepIndex: 2)

        await store.completeJob(id: jobId, result: AgentJobResult(
            summary: String(reply.prefix(200)),
            outputPath: nil, previewImagePath: nil, metadata: [:]
        ))
    }
}
