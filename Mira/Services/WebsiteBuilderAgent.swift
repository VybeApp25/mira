import Foundation

// MARK: - Website Builder Agent

enum WebsiteBuilderAgent {

    static func run(jobId: UUID, prompt: String, apiKey: String, store: AgentJobStore) async {
        let claude = ClaudeService(apiKey: apiKey)

        // Step 0: Analyzing requirements
        await store.updateStep(id: jobId, stepTitle: "Analyzing requirements", progress: 0.05, stepIndex: 0)
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Step 1: Generate structure
        await store.updateStep(id: jobId, stepTitle: "Generating structure", progress: 0.15, stepIndex: 1)

        let structurePrompt = """
        The user wants to build a website. Their request: "\(prompt)"

        In 2-3 sentences, describe:
        1. The site name
        2. The target audience
        3. The main sections (e.g. Hero, About, Services, Contact)

        Be concise. No markdown.
        """

        let structure: String
        do {
            structure = try await claude.ask(prompt: structurePrompt,
                                             system: "You are a professional web architect. Be precise and brief.",
                                             modelOverride: "claude-haiku-4-5-20251001")
        } catch {
            await store.failJob(id: jobId, error: "Failed to analyze requirements: \(error.localizedDescription)")
            return
        }

        await store.appendLog(id: jobId, stepIndex: 1, message: structure)

        // Step 2: Design
        await store.updateStep(id: jobId, stepTitle: "Creating design", progress: 0.30, stepIndex: 2)
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Step 3: Write code
        await store.updateStep(id: jobId, stepTitle: "Writing code", progress: 0.45, stepIndex: 3)

        let codePrompt = """
        Build a complete, beautiful, modern single-file website for the following request:

        "\(prompt)"

        Structure context: \(structure)

        Requirements:
        - Output ONLY valid HTML5 with embedded CSS and optional minimal JavaScript
        - Use a dark, modern design with gradients and clean typography
        - Include a hero section, at least 3 content sections, and a footer
        - Use system fonts (SF Pro, -apple-system, sans-serif)
        - Mobile-responsive with CSS flexbox or grid
        - Add smooth hover effects and transitions
        - Include placeholder content appropriate for the business/project
        - Do NOT use external CDN links — everything must be self-contained

        Output the complete HTML file only. No explanation. No markdown code blocks.
        Start with <!DOCTYPE html> and end with </html>.
        """

        let htmlCode: String
        do {
            htmlCode = try await claude.ask(prompt: codePrompt,
                                            system: "You are an expert web developer. Output only clean, production-ready HTML.",
                                            modelOverride: "claude-sonnet-4-6",
                                            maxTokensOverride: 4000)
        } catch {
            await store.failJob(id: jobId, error: "Failed to generate website code: \(error.localizedDescription)")
            return
        }

        // Step 4: Validate
        await store.updateStep(id: jobId, stepTitle: "Validating output", progress: 0.70, stepIndex: 4)
        let isValid = htmlCode.contains("<!DOCTYPE html>") || htmlCode.contains("<html")
        guard isValid else {
            await store.failJob(id: jobId, error: "Generated output was not valid HTML. Please try again.")
            return
        }

        // Step 5: Save to disk
        await store.updateStep(id: jobId, stepTitle: "Preparing preview", progress: 0.82, stepIndex: 5)

        let outputDir = websiteDirectory(for: jobId)
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let indexURL = outputDir.appendingPathComponent("index.html")
            try htmlCode.write(to: indexURL, atomically: true, encoding: .utf8)
        } catch {
            await store.failJob(id: jobId, error: "Failed to save website: \(error.localizedDescription)")
            return
        }

        // Step 6: Save project
        await store.updateStep(id: jobId, stepTitle: "Saving project", progress: 0.95, stepIndex: 6)
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Extract a clean title from the prompt
        let siteName = extractSiteName(from: prompt)
        let outputPath = outputDir.appendingPathComponent("index.html").path

        let result = AgentJobResult(
            summary: "Built \(siteName) — \(structure.components(separatedBy: ".").first ?? "website ready").",
            outputPath: outputPath,
            previewImagePath: nil,
            metadata: [
                "siteName": siteName,
                "outputDirectory": outputDir.path,
                "linesOfCode": "\(htmlCode.components(separatedBy: "\n").count)",
            ]
        )

        await store.completeJob(id: jobId, result: result)
    }

    // MARK: - Helpers

    private static func websiteDirectory(for jobId: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Mira/Projects/Websites/\(jobId.uuidString)", isDirectory: true)
    }

    private static func extractSiteName(from prompt: String) -> String {
        // Look for quoted name: "build a site for LOCKED Energy" → "LOCKED Energy"
        let words = prompt.components(separatedBy: " ")
        let forIdx = words.firstIndex(of: "for") ?? words.firstIndex(of: "FOR")
        if let idx = forIdx, idx + 1 < words.count {
            let remaining = words[(idx + 1)...].prefix(3).joined(separator: " ")
            let cleaned = remaining.trimmingCharacters(in: .punctuationCharacters)
            if !cleaned.isEmpty { return cleaned }
        }
        // Fallback: first 4 words of prompt, title-cased
        return words.prefix(4).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Research Agent (stub)

enum ResearchAgent {
    static func run(jobId: UUID, prompt: String, apiKey: String, store: AgentJobStore) async {
        let claude = ClaudeService(apiKey: apiKey)

        await store.updateStep(id: jobId, stepTitle: "Defining research scope", progress: 0.10, stepIndex: 0)
        try? await Task.sleep(nanoseconds: 500_000_000)

        await store.updateStep(id: jobId, stepTitle: "Gathering information", progress: 0.25, stepIndex: 1)

        let researchPrompt = """
        Conduct deep research on the following topic and produce a comprehensive report:

        "\(prompt)"

        Format your response as a structured report with:
        1. Executive Summary (2-3 sentences)
        2. Key Findings (5-7 bullet points)
        3. Detailed Analysis (3-4 paragraphs)
        4. Recommendations (3-5 actionable items)
        5. Conclusion

        Be thorough, factual, and insightful.
        """

        await store.updateStep(id: jobId, stepTitle: "Analyzing findings", progress: 0.45, stepIndex: 2)

        let report: String
        do {
            report = try await claude.ask(prompt: researchPrompt,
                                          system: "You are a senior research analyst. Produce thorough, well-structured reports.",
                                          modelOverride: "claude-sonnet-4-6")
        } catch {
            await store.failJob(id: jobId, error: "Research failed: \(error.localizedDescription)")
            return
        }

        await store.updateStep(id: jobId, stepTitle: "Synthesizing insights", progress: 0.65, stepIndex: 3)
        try? await Task.sleep(nanoseconds: 300_000_000)

        await store.updateStep(id: jobId, stepTitle: "Writing report", progress: 0.80, stepIndex: 4)

        // Save report to disk
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
        try? await Task.sleep(nanoseconds: 200_000_000)

        let summary = report.components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Research complete."

        let result = AgentJobResult(
            summary: summary,
            outputPath: fileURL.path,
            previewImagePath: nil,
            metadata: ["wordCount": "\(report.components(separatedBy: " ").count)"]
        )
        await store.completeJob(id: jobId, result: result)
    }
}

// MARK: - Content Agent (stub)

enum ContentAgent {
    static func run(jobId: UUID, prompt: String, apiKey: String, store: AgentJobStore) async {
        let claude = ClaudeService(apiKey: apiKey)

        await store.updateStep(id: jobId, stepTitle: "Understanding brief", progress: 0.10, stepIndex: 0)
        try? await Task.sleep(nanoseconds: 400_000_000)

        await store.updateStep(id: jobId, stepTitle: "Generating outline", progress: 0.25, stepIndex: 1)
        try? await Task.sleep(nanoseconds: 300_000_000)

        await store.updateStep(id: jobId, stepTitle: "Writing content", progress: 0.45, stepIndex: 2)

        let content: String
        do {
            content = try await claude.ask(
                prompt: prompt,
                system: "You are a professional content writer. Produce polished, engaging content tailored to the request.",
                modelOverride: "claude-sonnet-4-6"
            )
        } catch {
            await store.failJob(id: jobId, error: "Content generation failed: \(error.localizedDescription)")
            return
        }

        await store.updateStep(id: jobId, stepTitle: "Refining draft", progress: 0.80, stepIndex: 3)
        try? await Task.sleep(nanoseconds: 300_000_000)

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

        let firstLine = content.components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Content ready."
        let result = AgentJobResult(
            summary: firstLine,
            outputPath: fileURL.path,
            previewImagePath: nil,
            metadata: ["wordCount": "\(content.components(separatedBy: " ").count)"]
        )
        await store.completeJob(id: jobId, result: result)
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
                                         system: "You are Mira, a capable AI assistant. Complete the user's request thoroughly.")
        } catch {
            await store.failJob(id: jobId, error: error.localizedDescription)
            return
        }

        await store.updateStep(id: jobId, stepTitle: "Generating result", progress: 0.70, stepIndex: 1)
        try? await Task.sleep(nanoseconds: 300_000_000)

        await store.updateStep(id: jobId, stepTitle: "Saving output", progress: 0.95, stepIndex: 2)

        let result = AgentJobResult(
            summary: reply.prefix(200).description,
            outputPath: nil,
            previewImagePath: nil,
            metadata: [:]
        )
        await store.completeJob(id: jobId, result: result)
    }
}
