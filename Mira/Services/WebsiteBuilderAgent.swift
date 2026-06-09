import Foundation
import AppKit

// MARK: - Critic Report

struct CriticReport: Codable {
    let visualQuality: Int
    let conversionPotential: Int
    let mobileExperience: Int
    let accessibility: Int
    let brandConsistency: Int
    let findings: [String]

    var overallScore: Int {
        (visualQuality + conversionPotential + mobileExperience + accessibility + brandConsistency) / 5
    }
}

// MARK: - Supporting models

private struct ReferenceAnalysis {
    let layoutPattern: String
    let heroComposition: String
    let typographyStyle: String
    let colorLanguage: String
    let spacingSystem: String
    let sectionOrdering: String
    let animationStyle: String
    let ctaPlacement: String
    let visualDensity: String
    let qualityScore: Double
    let designBrief: String

    var injectionText: String {
        """
        REFERENCE ANALYSIS (extracted from \(Int(qualityScore * 10))/10 quality references):
        Layout Pattern: \(layoutPattern)
        Hero Composition: \(heroComposition)
        Typography Style: \(typographyStyle)
        Color Language: \(colorLanguage)
        Spacing System: \(spacingSystem)
        Section Order: \(sectionOrdering)
        Animation Style: \(animationStyle)
        CTA Placement: \(ctaPlacement)
        Visual Density: \(visualDensity)
        Design Brief: \(designBrief)
        """
    }
}

private struct DesignSpec {
    let genre: String
    let style: String
    let colorPalette: String
    let typography: String
    let layoutStyle: String
    let motionStyle: String
    let cardStyle: String
    let borderRadius: String
    let shadowSystem: String
    let referenceAnalysis: ReferenceAnalysis?

    var injectionText: String {
        var text = """
        DESIGN SPEC:
        Genre: \(genre)
        Style: \(style)
        Color Palette: \(colorPalette)
        Typography: \(typography)
        Layout: \(layoutStyle)
        Motion: \(motionStyle)
        Cards: \(cardStyle)
        Border Radius: \(borderRadius)
        Shadows: \(shadowSystem)
        """
        if let ref = referenceAnalysis {
            text += "\n\n" + ref.injectionText
        }
        return text
    }
}

// MARK: - Website Builder Agent

enum WebsiteBuilderAgent {

    static func run(jobId: UUID, prompt: String, apiKey: String, store: AgentJobStore,
                    buildMode: WebsiteBuildMode = .pro, referenceImagePaths: [String] = [],
                    userProvidedInfo: String? = nil) async {
        let claude = ClaudeService(apiKey: apiKey)
        var stepIdx = 0
        var previewImage: NSImage? = nil
        var criticReportJSON: String? = nil
        var augmentedUserInfo: String? = userProvidedInfo

        // ── Multi-Agent Pre-Build (Research → Brand Strategy → Copywriting) ───
        if buildMode == .multiAgent {
            augmentedUserInfo = await runMultiAgentPreBuild(
                prompt: prompt, claude: claude, jobId: jobId, store: store, stepIdx: &stepIdx
            )
            guard augmentedUserInfo != nil else { return }
        }

        // ── Stage 0: Requirements ─────────────────────────────────────────────
        if augmentedUserInfo == nil {
            await store.updateStep(id: jobId, stepTitle: "Collecting requirements", progress: 0.05, stepIndex: stepIdx)
            let readiness = await analyzeRequirements(prompt: prompt, claude: claude, buildMode: buildMode)
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Score: \(Int(readiness.score))% — \(readiness.summary)")
            if readiness.shouldAsk {
                await store.markWaitingForInput(id: jobId, readiness: readiness)
                return
            }
            if readiness.hasWarnings {
                await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Proceeding with assumptions: \(readiness.assumptions.joined(separator: ", "))")
            }
        }
        stepIdx += 1

        // ── Stage 1: Prompt Enrichment ────────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Enriching brief", progress: 0.10, stepIndex: stepIdx)
        var basePrompt = prompt
        if let extra = augmentedUserInfo, !extra.isEmpty {
            basePrompt += "\n\nAdditional details:\n\(extra)"
        }
        let (finalPrompt, enrichLog) = await enrichPrompt(basePrompt, claude: claude)
        await store.appendLog(id: jobId, stepIndex: stepIdx, message: enrichLog)
        stepIdx += 1

        // ── Stage 2: Reference Analysis ───────────────────────────────────────
        let allRefPaths = mergeReferencePaths(explicit: referenceImagePaths)
        let referenceImages = loadImagesFromPaths(allRefPaths)
        var referenceAnalysis: ReferenceAnalysis? = nil

        if buildMode.runReferenceAnalysis && !referenceImages.isEmpty {
            await store.updateStep(id: jobId, stepTitle: "Analyzing design references", progress: 0.18, stepIndex: stepIdx)
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Analyzing \(referenceImages.count) reference image\(referenceImages.count == 1 ? "" : "s")…")
            do {
                referenceAnalysis = try await analyzeReferences(images: referenceImages, apiKey: apiKey)
                if let ra = referenceAnalysis {
                    await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Quality: \(String(format: "%.1f", ra.qualityScore))/10 — \(ra.designBrief.prefix(80))")
                }
            } catch {
                await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Reference analysis skipped — \(error.localizedDescription)")
            }
        } else {
            await store.updateStep(id: jobId, stepTitle: "Loading design references", progress: 0.18, stepIndex: stepIdx)
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: referenceImages.isEmpty
                ? "No references — genre blueprint will drive design direction"
                : "Loaded \(referenceImages.count) reference image\(referenceImages.count == 1 ? "" : "s")")
        }
        stepIdx += 1

        // ── Stage 3: Design Direction ─────────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Creating design direction", progress: 0.25, stepIndex: stepIdx)
        let designSpec: DesignSpec
        do {
            designSpec = try await generateDesignSpec(
                prompt: finalPrompt,
                referenceImages: buildMode.runReferenceAnalysis ? [] : referenceImages,
                referenceAnalysis: referenceAnalysis,
                claude: claude
            )
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Genre: \(designSpec.genre) · \(designSpec.style) · \(designSpec.colorPalette.prefix(50))")
        } catch {
            await store.failJob(id: jobId, error: "Design direction failed: \(error.localizedDescription)")
            return
        }
        stepIdx += 1

        // ── Stage 4+: Generation ──────────────────────────────────────────────
        var finalHTML: String

        if buildMode == .studio {
            // Studio: 3 parallel variants → user picks one
            await store.updateStep(id: jobId, stepTitle: "Generating variants", progress: 0.35, stepIndex: stepIdx)
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Generating 3 design variants in parallel…")

            let variants = await generateVariants(
                prompt: finalPrompt,
                designSpec: designSpec,
                referenceAnalysis: referenceAnalysis,
                claude: claude
            )
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: "\(variants.count) variant\(variants.count == 1 ? "" : "s") ready — awaiting selection")
            stepIdx += 1

            await store.updateStep(id: jobId, stepTitle: "Awaiting selection", progress: 0.62, stepIndex: stepIdx)
            let selected = await store.requestVariantSelection(id: jobId, variants: variants)
            guard !selected.isEmpty else {
                await store.failJob(id: jobId, error: "Variant selection cancelled.")
                return
            }
            finalHTML = selected
            stepIdx += 1

        } else {
            // Fast / Pro: single-shot generation
            await store.updateStep(id: jobId, stepTitle: "Building website", progress: 0.35, stepIndex: stepIdx)
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Generating complete website in one shot…")
            do {
                finalHTML = try await generateWebsite(
                    prompt: finalPrompt, designSpec: designSpec,
                    referenceAnalysis: referenceAnalysis, buildMode: buildMode, claude: claude
                )
                let lines = finalHTML.components(separatedBy: "\n").count
                await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Generated \(lines) lines")
            } catch {
                await store.failJob(id: jobId, error: "Website generation failed: \(error.localizedDescription)")
                return
            }
            await store.updateStep(id: jobId, stepTitle: "Building website", progress: 0.70, stepIndex: stepIdx)
            stepIdx += 1

            // Pro / Multi-Agent: structural quality check + repair
            if buildMode.runsRepairPass {
                await store.updateStep(id: jobId, stepTitle: "Refining website", progress: 0.75, stepIndex: stepIdx)
                let failures = structuralQualityCheck(finalHTML)
                if failures.isEmpty {
                    await store.appendLog(id: jobId, stepIndex: stepIdx, message: "All structural checks passed")
                } else {
                    await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Fixing: \(failures.joined(separator: ", "))")
                    do {
                        finalHTML = try await repairWebsite(html: finalHTML, failures: failures, prompt: finalPrompt, claude: claude)
                        await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Repair complete")
                    } catch {
                        await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Repair skipped — using original")
                    }
                }
                stepIdx += 1
            }
        }

        // ── Stage: Visual Critique (Pro + Studio) ─────────────────────────────
        if buildMode != .fast {
            await store.updateStep(id: jobId, stepTitle: "Visual critique", progress: 0.82, stepIndex: stepIdx)
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Rendering preview — checking visual quality…")

            if let screenshot = await OffscreenRenderer.capture(html: finalHTML) {
                previewImage = screenshot
                await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Render complete — running visual critique")
                do {
                    let critiqued = try await visualCritiquePass(
                        html: finalHTML, screenshot: screenshot,
                        prompt: finalPrompt, designSpec: designSpec, claude: claude
                    )
                    finalHTML = critiqued
                    await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Visual critique applied")
                } catch {
                    await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Visual critique skipped — \(error.localizedDescription)")
                }
            } else {
                await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Render timed out — proceeding without visual check")
            }
            stepIdx += 1
        }

        // ── Quality Audit ─────────────────────────────────────────────────────
        if buildMode != .fast {
            await store.updateStep(id: jobId, stepTitle: "Quality audit", progress: 0.87, stepIndex: stepIdx)
            if let report = await runCriticPass(
                html: finalHTML, screenshot: previewImage,
                prompt: finalPrompt, designSpec: designSpec, claude: claude
            ) {
                if let data = try? JSONEncoder().encode(report),
                   let str = String(data: data, encoding: .utf8) {
                    criticReportJSON = str
                }
                await store.appendLog(id: jobId, stepIndex: stepIdx, message:
                    "Overall: \(report.overallScore)/10 · Visual:\(report.visualQuality) · Conversion:\(report.conversionPotential) · Mobile:\(report.mobileExperience)")
                if let finding = report.findings.first {
                    await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Top finding: \(finding.prefix(100))")
                }
            } else {
                await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Quality audit skipped")
            }
            stepIdx += 1
        }

        // ── Validation ────────────────────────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Validating", progress: 0.91, stepIndex: stepIdx)
        let validated = validateAndRepair(html: finalHTML)
        guard validated.isValid else {
            await store.failJob(id: jobId, error: validated.error ?? "HTML validation failed — please retry.")
            return
        }
        let cleanedHTML = validated.html
        stepIdx += 1

        // ── Approval ──────────────────────────────────────────────────────────
        let siteName = extractSiteName(from: finalPrompt)
        let lineCount = cleanedHTML.components(separatedBy: "\n").count
        let outputDir = websiteDirectory(for: jobId)
        await store.updateStep(id: jobId, stepTitle: "Awaiting approval", progress: 0.94, stepIndex: stepIdx)
        let confirmRequest = ConfirmationRequest(
            title: "Save \(siteName)?",
            summary: "Mira will write \(lineCount) lines of HTML to:\n\(outputDir.appendingPathComponent("index.html").path)",
            riskLevel: .low, approveLabel: "Save Website", denyLabel: "Discard"
        )
        let approved = await store.requestConfirmation(id: jobId, request: confirmRequest)
        guard approved else { return }
        stepIdx += 1

        // ── Save ──────────────────────────────────────────────────────────────
        await store.markWriting(id: jobId)
        await store.updateStep(id: jobId, stepTitle: "Saving project", progress: 0.97, stepIndex: stepIdx)
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            try cleanedHTML.write(to: outputDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            try designSpec.injectionText.write(to: outputDir.appendingPathComponent("design-spec.txt"), atomically: true, encoding: .utf8)
            if let ra = referenceAnalysis {
                try ra.injectionText.write(to: outputDir.appendingPathComponent("reference-analysis.txt"), atomically: true, encoding: .utf8)
            }
            if let reportJSON = criticReportJSON {
                try? reportJSON.write(to: outputDir.appendingPathComponent("critic-report.json"), atomically: true, encoding: .utf8)
            }
            if let image = previewImage,
               let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: outputDir.appendingPathComponent("preview.png"))
            }
        } catch {
            await store.failJob(id: jobId, error: "Failed to save website: \(error.localizedDescription)")
            return
        }

        let modeTag = buildMode.rawValue
        let previewPath: String? = previewImage != nil ? outputDir.appendingPathComponent("preview.png").path : nil
        var metadata: [String: String] = [
            "siteName": siteName,
            "genre": designSpec.genre,
            "designStyle": designSpec.style,
            "buildMode": modeTag,
            "outputDirectory": outputDir.path,
            "linesOfCode": "\(lineCount)",
            "referencesUsed": "\(referenceImages.count)",
        ]
        if let reportJSON = criticReportJSON {
            metadata["criticReport"] = reportJSON
        }
        await store.completeJob(id: jobId, result: AgentJobResult(
            summary: "Built \(siteName) — \(lineCount) lines · \(designSpec.genre) [\(modeTag)]",
            outputPath: outputDir.appendingPathComponent("index.html").path,
            previewImagePath: previewPath,
            metadata: metadata
        ))
    }

    // MARK: - Multi-Agent Pre-Build Pipeline

    /// Runs Research → Brand Strategy → Copywriting stages.
    /// Returns the combined context string to inject as userProvidedInfo, or nil on failure.
    private static func runMultiAgentPreBuild(
        prompt: String,
        claude: ClaudeService,
        jobId: UUID,
        store: AgentJobStore,
        stepIdx: inout Int
    ) async -> String? {

        // Stage 0: Market Research
        await store.updateStep(id: jobId, stepTitle: "Researching industry", progress: 0.06, stepIndex: stepIdx)
        let researchPrompt = """
        Research context for building a website: "\(prompt.prefix(600))"

        Provide a focused brief covering:
        1. Industry/market overview (2-3 sentences)
        2. Target audience — specific demographics, psychographics, pain points
        3. Key competitors and their positioning
        4. Messaging opportunities and differentiators
        5. Tone and language that resonates with this audience

        Be specific and actionable. Max 350 words.
        """
        guard let research = try? await claude.ask(
            prompt: researchPrompt,
            system: "You are a market research analyst. Be specific, not generic.",
            modelOverride: "claude-haiku-4-5-20251001",
            maxTokensOverride: 700
        ) else {
            await store.failJob(id: jobId, error: "Research stage failed. Please retry.")
            return nil
        }
        await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Market research complete")
        stepIdx += 1

        // Stage 1: Brand Strategy
        await store.updateStep(id: jobId, stepTitle: "Building brand strategy", progress: 0.14, stepIndex: stepIdx)
        let brandPrompt = """
        Based on this website request and market research, develop a brand strategy.

        REQUEST: "\(prompt.prefix(400))"

        RESEARCH:
        \(research.prefix(800))

        Output exactly:
        Brand Voice: [3-4 adjectives describing how this brand speaks]
        Key Message 1: [most important takeaway]
        Key Message 2: [second most important]
        Key Message 3: [third most important]
        Hero Headline Direction: [the emotional angle for the hero section]
        Tagline: [5-7 word brand tagline]
        Differentiation: [what makes this brand stand out]

        Max 200 words. Specific to this brand only.
        """
        guard let brand = try? await claude.ask(
            prompt: brandPrompt,
            system: "You are a brand strategist. Output only the brand strategy, nothing else.",
            modelOverride: "claude-haiku-4-5-20251001",
            maxTokensOverride: 500
        ) else {
            await store.failJob(id: jobId, error: "Brand strategy stage failed.")
            return nil
        }
        await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Brand strategy ready")
        stepIdx += 1

        // Stage 2: Copywriting
        await store.updateStep(id: jobId, stepTitle: "Writing copy", progress: 0.24, stepIndex: stepIdx)
        let copyPrompt = """
        Write real website copy for this project.

        REQUEST: "\(prompt.prefix(400))"
        BRAND STRATEGY: \(brand.prefix(600))

        Write the following (use these exact labels):
        HERO_HEADLINE: [bold, specific, max 8 words]
        HERO_SUBTEXT: [2 sentences expanding on the headline]
        HERO_CTA: [action-oriented button text, 2-4 words]
        FEATURE_1_TITLE: [3-5 words, benefit-focused]
        FEATURE_1_DESC: [2 sentences]
        FEATURE_2_TITLE: [3-5 words]
        FEATURE_2_DESC: [2 sentences]
        FEATURE_3_TITLE: [3-5 words]
        FEATURE_3_DESC: [2 sentences]
        TESTIMONIAL_1: ["exact quote" — Real Name, Real Title, Real Company]
        TESTIMONIAL_2: ["exact quote" — Real Name, Real Title, Real Company]
        CLOSING_HEADLINE: [final section headline]
        CLOSING_CTA: [final button text]

        Use the brand voice. Every line must be specific to this business. No placeholders.
        """
        guard let copy = try? await claude.ask(
            prompt: copyPrompt,
            system: "You are a professional copywriter. Write real, specific copy. No generic placeholders ever.",
            modelOverride: "claude-sonnet-4-6",
            maxTokensOverride: 1200
        ) else {
            await store.failJob(id: jobId, error: "Copywriting stage failed.")
            return nil
        }
        await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Copy written — \(copy.components(separatedBy: "\n").count) lines")
        stepIdx += 1

        // Stage 3: Creative Director
        await store.updateStep(id: jobId, stepTitle: "Creative direction", progress: 0.33, stepIndex: stepIdx)
        let creativeDirection: String
        do {
            let creativePrompt = """
            You are a Creative Director. A website is about to be built. Review this brief and provide precise visual direction.

            REQUEST: "\(prompt.prefix(300))"

            MARKET RESEARCH:
            \(research.prefix(500))

            BRAND STRATEGY:
            \(brand.prefix(400))

            WEBSITE COPY:
            \(copy.prefix(500))

            Output EXACTLY these labels with specific, actionable direction:
            VISUAL_STYLE: [e.g. "Dark editorial — deep navy, gold serif headlines, generous whitespace, luxury feel"]
            TYPOGRAPHY_DIRECTION: [specific font pairing + why it fits this brand's audience]
            LAYOUT_STRATEGY: [hero structure, how sections flow, visual emphasis priorities]
            COLOR_PSYCHOLOGY: [exact hex values or descriptive palette + psychological rationale for this audience]
            CTA_STRATEGY: [how CTAs should look, feel, be positioned — very specific]
            CONVERSION_RECS: [3 numbered recommendations specific to this business and audience]
            DESIGN_AVOID: [1-2 design patterns that would hurt this brand]

            Be highly specific. No generic advice. This becomes the visual brief for the website builder.
            Max 280 words.
            """
            creativeDirection = try await claude.ask(
                prompt: creativePrompt,
                system: "You are a Creative Director at a top agency. Output only the structured creative direction. No preamble, no explanation.",
                modelOverride: "claude-sonnet-4-6",
                maxTokensOverride: 700
            )
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Creative direction ready")
        } catch {
            creativeDirection = ""
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Creative direction skipped")
        }
        stepIdx += 1

        // Stage 4: Preference Engine
        await store.updateStep(id: jobId, stepTitle: "Applying preferences", progress: 0.38, stepIndex: stepIdx)
        let (jobSnapshot, entrySnapshot) = await MainActor.run {
            (AgentJobStore.shared.jobs, OutputStore.shared.entries)
        }
        let profile = PreferenceEngine.compute(jobs: jobSnapshot, entries: entrySnapshot)
        if profile.isEmpty {
            await store.appendLog(id: jobId, stepIndex: stepIdx,
                                  message: "No preference profile yet — \(profile.dataPointsAnalyzed) project(s) analyzed")
        } else {
            await store.appendLog(id: jobId, stepIndex: stepIdx,
                                  message: "Applied \(profile.preferences.count) preference signal(s) from \(profile.dataPointsAnalyzed) project(s)")
        }
        stepIdx += 1

        return """
        MULTI-AGENT PIPELINE OUTPUT — USE ALL OF THIS:

        ── MARKET RESEARCH ──
        \(research)

        ── BRAND STRATEGY ──
        \(brand)

        ── WEBSITE COPY (use these exact words in the site) ──
        \(copy)
        \(creativeDirection.isEmpty ? "" : "\n── CREATIVE DIRECTION (visual brief — follow this precisely) ──\n\(creativeDirection)")
        \(profile.isEmpty ? "" : "\n\(profile.injectionBlock)")
        """
    }

    // MARK: - Quality Audit (Website Critic)

    private static func runCriticPass(
        html: String,
        screenshot: NSImage?,
        prompt: String,
        designSpec: DesignSpec,
        claude: ClaudeService
    ) async -> CriticReport? {
        let scoreInstructions = """
        Score each dimension 1–10 (10 = world-class, 7 = good, 5 = average, below 5 = problem):
        1. visualQuality — typography hierarchy, design polish, use of space, overall premium feel
        2. conversionPotential — CTA clarity, value proposition strength, trust signals, urgency
        3. mobileExperience — responsive layout quality, mobile readability, touch-friendly sizing
        4. accessibility — color contrast ratios, semantic structure, readable font sizes
        5. brandConsistency — cohesive palette, consistent voice, professional presentation

        Then provide exactly 5 specific, actionable improvement recommendations.

        Respond ONLY with valid JSON — no markdown, no explanation:
        {
          "visualQuality": <1-10>,
          "conversionPotential": <1-10>,
          "mobileExperience": <1-10>,
          "accessibility": <1-10>,
          "brandConsistency": <1-10>,
          "findings": [
            "<specific improvement 1>",
            "<specific improvement 2>",
            "<specific improvement 3>",
            "<specific improvement 4>",
            "<specific improvement 5>"
          ]
        }
        """
        do {
            let raw: String
            if let screenshot = screenshot {
                let prompt = """
                Review this \(designSpec.genre) website screenshot.
                Original request: "\(prompt.prefix(300))"
                Genre: \(designSpec.genre) · Style: \(designSpec.style)

                \(scoreInstructions)
                """
                raw = try await claude.ask(
                    prompt: prompt,
                    screenshot: screenshot,
                    system: "You are a senior UX and conversion expert. Score the website and output only JSON.",
                    modelOverride: "claude-sonnet-4-6",
                    maxTokensOverride: 700
                )
            } else {
                let prompt = """
                Review this \(designSpec.genre) website HTML.
                Original request: "\(prompt.prefix(300))"
                Genre: \(designSpec.genre) · Style: \(designSpec.style)

                \(scoreInstructions)

                HTML (first 10000 chars):
                \(html.prefix(10000))
                """
                raw = try await claude.ask(
                    prompt: prompt,
                    system: "You are a senior UX and conversion expert. Output only JSON.",
                    modelOverride: "claude-haiku-4-5-20251001",
                    maxTokensOverride: 600
                )
            }
            return parseCriticReport(from: raw)
        } catch {
            return nil
        }
    }

    fileprivate static func parseCriticReport(from text: String) -> CriticReport? {
        guard let range = text.range(of: #"\{[\s\S]*\}"#, options: .regularExpression),
              let data = String(text[range]).data(using: .utf8) else { return nil }
        struct Raw: Decodable {
            let visualQuality: Int
            let conversionPotential: Int
            let mobileExperience: Int
            let accessibility: Int
            let brandConsistency: Int
            let findings: [String]
        }
        guard let r = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        return CriticReport(
            visualQuality: max(1, min(10, r.visualQuality)),
            conversionPotential: max(1, min(10, r.conversionPotential)),
            mobileExperience: max(1, min(10, r.mobileExperience)),
            accessibility: max(1, min(10, r.accessibility)),
            brandConsistency: max(1, min(10, r.brandConsistency)),
            findings: r.findings
        )
    }

    // MARK: - Stage 1: Prompt Enrichment

    private static func enrichPrompt(_ prompt: String, claude: ClaudeService) async -> (enriched: String, log: String) {
        var enriched = prompt
        var logs: [String] = []

        // URL fetch — pull source content if a URL is present in the prompt
        if let url = extractURL(from: prompt) {
            do {
                var req = URLRequest(url: url)
                req.setValue("Mozilla/5.0 (compatible; Mira/1.0)", forHTTPHeaderField: "User-Agent")
                req.timeoutInterval = 10
                let (data, _) = try await URLSession.shared.data(for: req)
                let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                if !html.isEmpty {
                    let text = stripHTMLTags(html)
                    enriched += "\n\nSOURCE CONTENT FROM \(url.host ?? url.absoluteString):\n\(text.prefix(3000))"
                    logs.append("Fetched \(url.host ?? "URL")")
                }
            } catch {
                logs.append("URL fetch skipped")
            }
        }

        // Logo color extraction — check DesignReferences/logo.png
        let logoPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mira/DesignReferences/logo.png").path
        if FileManager.default.fileExists(atPath: logoPath) {
            let colors = extractBrandColors(from: logoPath)
            if !colors.isEmpty {
                enriched += "\n\nEXTRACTED BRAND COLORS FROM LOGO: \(colors.joined(separator: ", "))"
                enriched += "\nUse these as the primary color palette — this is the actual brand."
                logs.append("Brand colors: \(colors.joined(separator: " "))")
            }
        }

        // QualityStore — inject high-rated styles for this genre
        let estimatedGenre = detectGenre(from: prompt, specStyle: "")
        let topStyles = QualityStore.shared.topStylesForGenre(estimatedGenre)
        if !topStyles.isEmpty {
            enriched += "\n\nHIGH-RATED DESIGN STYLES FOR \(estimatedGenre.uppercased()):\n"
            enriched += topStyles.map { "- \($0)" }.joined(separator: "\n")
            enriched += "\nThese styles have produced highly-rated results for this type of site."
            logs.append("Applied \(topStyles.count) learned style\(topStyles.count == 1 ? "" : "s")")
        }

        // Brief expansion — only for sparse prompts (saves time on detailed ones)
        let wordCount = prompt.split(separator: " ").count
        guard wordCount < 30 else {
            logs.append("Detailed prompt — skipping expansion")
            return (enriched, logs.isEmpty ? "Prompt ready" : logs.joined(separator: " · "))
        }

        do {
            let expansionPrompt = """
            A client wants this website: "\(prompt)"

            Invent a complete, realistic business brief. Be specific — real brand names, real numbers, real copy. No placeholders.

            Respond ONLY with JSON, no markdown:
            {
              "businessName": "<specific brand name>",
              "tagline": "<punchy 5-7 word tagline>",
              "description": "<2-3 sentence business description>",
              "audience": "<target audience>",
              "features": ["<feature 1>", "<feature 2>", "<feature 3>", "<feature 4>", "<feature 5>"],
              "pricingTiers": [
                {"name": "<tier>", "price": "<$X/mo>", "highlights": ["<feature>", "<feature>"]},
                {"name": "<tier>", "price": "<$X/mo>", "highlights": ["<feature>", "<feature>", "<feature>"]},
                {"name": "<tier>", "price": "<$X/mo>", "highlights": ["<feature>", "<feature>", "<feature>", "<feature>"]}
              ],
              "testimonials": [
                {"quote": "<quote>", "name": "<Name>", "role": "<Role>", "company": "<Company>"},
                {"quote": "<quote>", "name": "<Name>", "role": "<Role>", "company": "<Company>"},
                {"quote": "<quote>", "name": "<Name>", "role": "<Role>", "company": "<Company>"}
              ],
              "cta": "<main call-to-action text>",
              "stats": [{"value": "<X+>", "label": "<metric>"}, {"value": "<X>", "label": "<metric>"}, {"value": "<X>", "label": "<metric>"}]
            }
            """
            let raw = try await claude.ask(
                prompt: expansionPrompt,
                system: "You are a brand strategist. Output only JSON. Be specific — no generic placeholders.",
                modelOverride: "claude-haiku-4-5-20251001",
                maxTokensOverride: 2000
            )
            if let range = raw.range(of: #"\{[\s\S]*\}"#, options: .regularExpression) {
                enriched += "\n\nEXPANDED BRIEF:\n\(String(raw[range]))"
                logs.append("Brief expanded")
            }
        } catch {
            logs.append("Brief expansion skipped")
        }

        return (enriched, logs.isEmpty ? "Prompt ready" : logs.joined(separator: " · "))
    }

    private static func extractURL(from text: String) -> URL? {
        guard let range = text.range(of: #"https?://[^\s]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }

    private static func stripHTMLTags(_ html: String) -> String {
        var result = html
        result = result.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Logo Color Extraction (Task 5)

    static func extractBrandColors(from imagePath: String) -> [String] {
        guard let image = NSImage(contentsOfFile: imagePath),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return [] }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rawData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &rawData, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var colorCounts: [String: Int] = [:]
        let sampleStep = max(1, width / 20)

        for x in stride(from: 0, to: width, by: sampleStep) {
            for y in stride(from: 0, to: height, by: sampleStep) {
                let offset = (y * width + x) * bytesPerPixel
                let r = Int(rawData[offset])
                let g = Int(rawData[offset + 1])
                let b = Int(rawData[offset + 2])
                let a = Int(rawData[offset + 3])
                guard a > 128 else { continue }
                guard !(r > 220 && g > 220 && b > 220) else { continue }
                guard !(r < 30 && g < 30 && b < 30) else { continue }
                let qr = (r / 32) * 32
                let qg = (g / 32) * 32
                let qb = (b / 32) * 32
                let hex = String(format: "#%02X%02X%02X", qr, qg, qb)
                colorCounts[hex, default: 0] += 1
            }
        }

        return colorCounts
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)
    }

    // MARK: - Design References

    static func mergeReferencePaths(explicit: [String]) -> [String] {
        let refsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mira/DesignReferences", isDirectory: true)
        let folderPaths: [String] = {
            guard let items = try? FileManager.default.contentsOfDirectory(at: refsDir, includingPropertiesForKeys: nil) else { return [] }
            let exts: Set<String> = ["png", "jpg", "jpeg", "webp"]
            return items.filter { exts.contains($0.pathExtension.lowercased()) }.map(\.path)
        }()
        let all = explicit + folderPaths
        var seen = Set<String>()
        return all.filter { seen.insert($0).inserted }.prefix(5).map { $0 }
    }

    static func loadImagesFromPaths(_ paths: [String]) -> [(data: String, mime: String)] {
        paths.prefix(5).compactMap { path -> (String, String)? in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            let mime = path.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
            return (data.base64EncodedString(), mime)
        }
    }

    // MARK: - Reference Analysis Engine

    private static func analyzeReferences(images: [(data: String, mime: String)], apiKey: String) async throws -> ReferenceAnalysis {
        struct ContentBlock: Encodable {
            let type: String
            let source: ImageSource?
            let text: String?

            struct ImageSource: Encodable {
                let type: String
                let media_type: String
                let data: String
            }

            static func image(_ data: String, mime: String) -> ContentBlock {
                ContentBlock(type: "image", source: ImageSource(type: "base64", media_type: mime, data: data), text: nil)
            }

            static func text(_ t: String) -> ContentBlock {
                ContentBlock(type: "text", source: nil, text: t)
            }
        }

        struct Message: Encodable {
            let role: String
            let content: [ContentBlock]
        }

        struct APIRequest: Encodable {
            let model: String
            let max_tokens: Int
            let system: String
            let messages: [Message]
        }

        var contentBlocks: [ContentBlock] = images.map { .image($0.data, mime: $0.mime) }
        contentBlocks.append(.text("""
        Analyze these \(images.count) design reference image(s). Extract the design language for website generation.

        Respond ONLY with JSON, no markdown:
        {
          "layoutPattern": "<e.g. Full-width sections with centered content>",
          "heroComposition": "<e.g. Large headline, short subtext, two CTA buttons>",
          "typographyStyle": "<e.g. Heavy display font for headlines, light body>",
          "colorLanguage": "<e.g. Dark navy background, white text, electric blue accent>",
          "spacingSystem": "<e.g. Generous 120px+ section padding>",
          "sectionOrdering": "<e.g. Nav > Hero > Logos > Features > Testimonials > CTA > Footer>",
          "animationStyle": "<e.g. Subtle fade-in scroll, hover lifts on cards>",
          "ctaPlacement": "<e.g. Prominent hero CTA with ghost secondary>",
          "visualDensity": "<e.g. Low density — lots of whitespace>",
          "qualityScore": <0.0-1.0>,
          "designBrief": "<2-3 sentence brief on what makes these designs premium>"
        }
        """))

        let request = APIRequest(
            model: "claude-sonnet-4-6", max_tokens: 1000,
            system: "You are a senior design analyst. Output only JSON.",
            messages: [Message(role: "user", content: contentBlocks)]
        )

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 60
        req.httpBody = try JSONEncoder().encode(request)

        struct APIResponse: Decodable {
            let content: [Block]
            struct Block: Decodable { let type: String; let text: String? }
            var text: String { content.compactMap(\.text).joined() }
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MiraError.api(String(data: data, encoding: .utf8) ?? "Analysis failed")
        }
        return parseReferenceAnalysis(from: try JSONDecoder().decode(APIResponse.self, from: data).text)
    }

    private static func parseReferenceAnalysis(from text: String) -> ReferenceAnalysis {
        struct Raw: Decodable {
            let layoutPattern, heroComposition, typographyStyle, colorLanguage: String
            let spacingSystem, sectionOrdering, animationStyle, ctaPlacement, visualDensity: String
            let qualityScore: Double
            let designBrief: String
        }
        if let range = text.range(of: #"\{[\s\S]*\}"#, options: .regularExpression),
           let jsonData = String(text[range]).data(using: .utf8),
           let r = try? JSONDecoder().decode(Raw.self, from: jsonData) {
            return ReferenceAnalysis(
                layoutPattern: r.layoutPattern, heroComposition: r.heroComposition,
                typographyStyle: r.typographyStyle, colorLanguage: r.colorLanguage,
                spacingSystem: r.spacingSystem, sectionOrdering: r.sectionOrdering,
                animationStyle: r.animationStyle, ctaPlacement: r.ctaPlacement,
                visualDensity: r.visualDensity, qualityScore: r.qualityScore,
                designBrief: r.designBrief
            )
        }
        return ReferenceAnalysis(
            layoutPattern: "Full-width sections", heroComposition: "Large headline, subtext, CTA",
            typographyStyle: "Bold display, light body", colorLanguage: "Dark with single accent",
            spacingSystem: "Generous 100px+ section padding", sectionOrdering: "Nav > Hero > Features > CTA > Footer",
            animationStyle: "Subtle scroll animations", ctaPlacement: "Hero + final section",
            visualDensity: "Low density with whitespace", qualityScore: 0.85,
            designBrief: "Premium, modern design with strong visual hierarchy and generous whitespace."
        )
    }

    // MARK: - Stage 3: Design Spec

    private static func generateDesignSpec(
        prompt: String,
        referenceImages: [(data: String, mime: String)],
        referenceAnalysis: ReferenceAnalysis?,
        claude: ClaudeService
    ) async throws -> DesignSpec {

        let referenceContext: String
        if let ra = referenceAnalysis {
            referenceContext = "DESIGN REFERENCE ANALYSIS:\n\(ra.injectionText)\nYour design spec MUST derive from these patterns."
        } else if !referenceImages.isEmpty {
            referenceContext = "I am providing \(referenceImages.count) design reference image(s). Incorporate their visual language."
        } else {
            referenceContext = "No references. Use the genre and request to determine the ideal design direction."
        }

        let specPrompt = """
        You are a senior brand and web designer. A client needs a premium website.

        CLIENT REQUEST: "\(prompt.prefix(2000))"

        \(referenceContext)

        Generate a DESIGN SPEC. Output ONLY valid JSON, no markdown:
        {
          "genre": "<one of: saas | portfolio | ecommerce | restaurant | agency | event | blog>",
          "style": "<design style>",
          "colorPalette": "<3-4 specific hex values with roles>",
          "typography": "<font stack and scale description>",
          "layoutStyle": "<layout description>",
          "motionStyle": "<animation description>",
          "cardStyle": "<card design description>",
          "borderRadius": "<radius values>",
          "shadowSystem": "<shadow definitions>"
        }
        """

        let raw = try await claude.ask(
            prompt: specPrompt,
            system: "You are a world-class digital designer. Output only JSON. Be specific with hex values and measurements.",
            modelOverride: "claude-sonnet-4-6",
            maxTokensOverride: 900
        )
        return parseDesignSpec(from: raw, fallbackPrompt: prompt, referenceAnalysis: referenceAnalysis)
    }

    private static func parseDesignSpec(from text: String, fallbackPrompt: String, referenceAnalysis: ReferenceAnalysis? = nil) -> DesignSpec {
        struct Raw: Decodable {
            let genre: String?
            let style, colorPalette, typography, layoutStyle: String
            let motionStyle, cardStyle, borderRadius, shadowSystem: String
        }
        if let range = text.range(of: #"\{[\s\S]*\}"#, options: .regularExpression),
           let data = String(text[range]).data(using: .utf8),
           let r = try? JSONDecoder().decode(Raw.self, from: data) {
            let genre = normalizeGenre(r.genre) ?? detectGenre(from: fallbackPrompt, specStyle: r.style)
            return DesignSpec(genre: genre, style: r.style, colorPalette: r.colorPalette,
                              typography: r.typography, layoutStyle: r.layoutStyle,
                              motionStyle: r.motionStyle, cardStyle: r.cardStyle,
                              borderRadius: r.borderRadius, shadowSystem: r.shadowSystem,
                              referenceAnalysis: referenceAnalysis)
        }
        let lower = fallbackPrompt.lowercased()
        let style = lower.contains("real estate") || lower.contains("luxury") ? "Luxury Real Estate"
                  : lower.contains("saas") || lower.contains("software") || lower.contains("app") ? "Modern SaaS"
                  : lower.contains("agency") || lower.contains("studio") ? "Creative Agency"
                  : lower.contains("portfolio") ? "Minimal Portfolio"
                  : "Modern SaaS"
        return DesignSpec(
            genre: detectGenre(from: fallbackPrompt, specStyle: style), style: style,
            colorPalette: "Background #0A0F1C, Primary #4F9EFF, Accent #FF6B35, Text #F0F4FF",
            typography: "System sans-serif: 80px hero, 48px h2, 22px body, 14px caption",
            layoutStyle: "Full-width sections, 1280px content max-width, asymmetric hero",
            motionStyle: "Fade-in on scroll, hover card lifts 8px",
            cardStyle: "Glassmorphism: background rgba(255,255,255,0.05), blur(20px), 1px rgba(255,255,255,0.1) border",
            borderRadius: "Cards: 20px, Buttons: 50px pill, Images: 16px",
            shadowSystem: "Cards: 0 24px 64px rgba(0,0,0,0.4), Glow: 0 0 80px rgba(79,158,255,0.15)",
            referenceAnalysis: referenceAnalysis
        )
    }

    private static func normalizeGenre(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let g = raw.lowercased()
        if g.contains("saas") || g.contains("software") || g.contains("app") || g.contains("product") { return "saas" }
        if g.contains("portfolio") || g.contains("personal") { return "portfolio" }
        if g.contains("ecommerce") || g.contains("shop") || g.contains("store") || g.contains("commerce") { return "ecommerce" }
        if g.contains("restaurant") || g.contains("food") || g.contains("cafe") || g.contains("dining") { return "restaurant" }
        if g.contains("agency") || g.contains("studio") { return "agency" }
        if g.contains("event") || g.contains("conference") || g.contains("launch") { return "event" }
        if g.contains("blog") || g.contains("editorial") || g.contains("publication") { return "blog" }
        return nil
    }

    private static func detectGenre(from prompt: String, specStyle: String) -> String {
        let c = (prompt + " " + specStyle).lowercased()
        if c.contains("restaurant") || c.contains("food") || c.contains("cafe") || c.contains("dining") || c.contains("menu") { return "restaurant" }
        if c.contains("portfolio") || c.contains("freelance") || c.contains("photographer") || c.contains("illustrator") { return "portfolio" }
        if c.contains("shop") || c.contains("store") || c.contains("ecommerce") || c.contains("product") || c.contains("brand") { return "ecommerce" }
        if c.contains("agency") || c.contains("studio") || c.contains("creative") { return "agency" }
        if c.contains("event") || c.contains("conference") || c.contains("concert") || c.contains("launch") { return "event" }
        if c.contains("blog") || c.contains("newsletter") || c.contains("publication") || c.contains("editorial") { return "blog" }
        return "saas"
    }

    // MARK: - Stage 4: Single-Shot Generation

    private static func generateWebsite(
        prompt: String,
        designSpec: DesignSpec,
        referenceAnalysis: ReferenceAnalysis?,
        buildMode: WebsiteBuildMode,
        claude: ClaudeService
    ) async throws -> String {
        let blueprint = genreBlueprint(for: designSpec.genre)
        let refContext = referenceAnalysis.map { "REFERENCE ANALYSIS:\n\($0.injectionText)\n\n" } ?? ""
        let example = exampleContext(for: designSpec.genre)

        let masterPrompt = """
        You are the world's best web designer and developer. Output a complete, stunning, production-quality website in one shot.

        REQUEST: \(prompt.prefix(8000))

        \(example)DESIGN SPEC:
        Genre: \(designSpec.genre) · Style: \(designSpec.style)
        Colors: \(designSpec.colorPalette)
        Typography: \(designSpec.typography)
        Layout: \(designSpec.layoutStyle) · Motion: \(designSpec.motionStyle)
        Cards: \(designSpec.cardStyle) · Radius: \(designSpec.borderRadius) · Shadows: \(designSpec.shadowSystem)

        \(refContext)\(blueprint)

        ============================================================
        NON-NEGOTIABLE RULES
        ============================================================

        FONTS: @import 2 Google Fonts at top of <style> — bold display font + clean body font (never system-ui alone)
        SIZES: Hero h1: clamp(40px,6vw,80px) weight 800 tracking -2px · Section h2: clamp(28px,4vw,52px) weight 800

        CSS VARIABLES: :root must define --bg --bg2 --bg3 --text --text2 --text3 --accent --accent2 --border --radius --radius-sm --radius-lg
        All component colors use var() — never hardcoded hex in component rules
        Buttons: transition:all 0.2s ease + :hover{opacity:.85} · Cards: :hover{transform:translateY(-2px)} transition:0.2s

        CONTENT: Use EXPANDED BRIEF names/prices/quotes exactly if present — otherwise invent specific realistic content
        Banned: "Lorem ipsum", "Your title here", "Coming soon", "placeholder"

        SECTIONS: Every section needs real visual elements — cards, grids, mockups, stats — never text-only
        Sections alternate --bg / --bg2 backgrounds · Features:3+ cards with icon · Pricing:3 tiers (middle="Most Popular")
        Testimonials: avatar circle + quote + name/role/company · Stats: 48px+ numbers in a row

        RESPONSIVE: @media(max-width:768px) at CSS end — single column, hide hero visual (display:none)
        SCROLL: html{scroll-behavior:smooth} + nav box-shadow on scroll via inline <script>

        ============================================================
        OUTPUT: <!DOCTYPE html> on line 1 · complete file · no markdown fences · no explanation
        ============================================================
        """

        let html = try await claude.ask(
            prompt: masterPrompt,
            system: "You are the world's best web designer and developer. Output a single complete HTML file starting with <!DOCTYPE html>. No markdown fences, no explanation.",
            modelOverride: "claude-sonnet-4-6",
            maxTokensOverride: 8000
        )
        return stripMarkdownFences(html)
    }

    // MARK: - Genre Blueprints

    private static func genreBlueprint(for genre: String) -> String {
        let blueprints: [String: String] = [
            "saas": """
            GENRE BLUEPRINT: SaaS / Product
            AESTHETIC: Clean, minimal, modern. One strong accent on light or dark background.
            SECTION ORDER: Nav → Hero (headline + product UI mockup) → Logo bar → Feature splits (2, alternating) → Features grid (3 cards) → Pricing (3 tiers) → Testimonials (2×2 grid) → CTA banner → Footer
            HERO VISUAL: Build a fake dashboard — metric cards, bar chart from divs, activity feed. Make it look like a real SaaS product screenshot.
            FONTS: Display font with tight letter-spacing. Clean readable body.
            COLORS: White or near-black background, one blue/indigo/violet accent.
            """,
            "portfolio": """
            GENRE BLUEPRINT: Portfolio / Personal
            AESTHETIC: Editorial, spacious, typographic. Let the work breathe.
            SECTION ORDER: Nav → Hero (name + title + bio + availability badge) → Selected work grid (3-4 project cards) → About / process → Skills pill list → Testimonials (2 cards) → Contact → Footer
            HERO VISUAL: Grid of project thumbnail cards with colored backgrounds.
            FONTS: Strong serif or display for headlines. Clean sans body.
            COLORS: Near-white or cream background, dark text, one accent.
            """,
            "ecommerce": """
            GENRE BLUEPRINT: E-commerce / Brand
            AESTHETIC: Product-forward, bold, warm. Photography-first layout.
            SECTION ORDER: Nav → Hero (product headline + product visual + CTA) → Product grid (3-4 cards) → Brand story → Benefits (3 icon cards) → Reviews (3 cards) → Newsletter → Footer
            HERO VISUAL: Centered product mockup div with brand colors, product name, CTA.
            FONTS: Bold display. Warm approachable body.
            COLORS: Warm neutrals, cream or off-white, brand accent.
            """,
            "restaurant": """
            GENRE BLUEPRINT: Restaurant / Food
            AESTHETIC: Moody, rich, atmospheric. Earthy or deep colors. Serif elegance.
            SECTION ORDER: Nav → Hero (name + tagline + reserve button) → Menu highlights (3-4 dish cards) → About / story → Features (3 cards) → Testimonials (3 review cards) → Hours + location → Footer
            HERO VISUAL: Full-width styled div with rich background, restaurant name in large serif, reserve button.
            FONTS: Elegant serif headlines. Refined body.
            COLORS: Deep rich background, warm cream text, gold accent.
            """,
            "agency": """
            GENRE BLUEPRINT: Agency / Studio
            AESTHETIC: Bold, confident, typographic. Black dominant.
            SECTION ORDER: Nav → Hero (bold statement + stats) → Case studies grid (3 cards) → Services (4-6 items) → Process steps (1-4) → Team cards → Client logos → CTA banner → Footer
            HERO VISUAL: Oversized typography with stats row — "120+ Projects", "8 Years", "40+ Clients".
            FONTS: Ultra-bold display. Clean body.
            COLORS: Black or near-black, white text, one electric accent.
            """,
            "event": """
            GENRE BLUEPRINT: Event / Launch
            AESTHETIC: High energy, dramatic. Dark background dominant.
            SECTION ORDER: Nav → Hero (event name + date + location + CTA) → Countdown timer (live JS) → Speakers grid → About → Ticket tiers (3 cards) → FAQ (accordion) → Footer
            HERO VISUAL: Event name in huge typography with live countdown timer.
            FONTS: Bold condensed display. Clean sans body.
            COLORS: Dark/black background, white text, vibrant accent.
            """,
            "blog": """
            GENRE BLUEPRINT: Blog / Editorial
            AESTHETIC: Quiet, readable, content-first. Typography is the design.
            SECTION ORDER: Nav → Hero (featured post, full-width) → Post grid (3-4 article cards) → Categories bar → Newsletter → About the author → Footer
            HERO VISUAL: Large featured article card with gradient thumbnail, category tag, headline, excerpt.
            FONTS: Strong serif headlines. Highly readable body.
            COLORS: Warm white background, dark text, minimal accent.
            """
        ]
        return blueprints[genre] ?? blueprints["saas"]!
    }

    // MARK: - Example Library (Task 2)

    static func loadGenreExample(for genre: String) -> String? {
        let examplesDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mira/Examples")
        return try? String(contentsOf: examplesDir.appendingPathComponent("\(genre).html"), encoding: .utf8)
    }

    static func saveGenreExample(html: String, genre: String) {
        let examplesDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mira/Examples")
        try? FileManager.default.createDirectory(at: examplesDir, withIntermediateDirectories: true)
        try? html.write(to: examplesDir.appendingPathComponent("\(genre).html"), atomically: true, encoding: .utf8)
    }

    private static func exampleContext(for genre: String) -> String {
        guard let example = loadGenreExample(for: genre) else { return "" }
        let excerpt = String(example.prefix(6000))
        return """
        QUALITY REFERENCE — STUDY THIS APPROVED EXAMPLE:
        Below is a high-quality \(genre) website. Study its CSS architecture, visual depth,
        typography scale, card patterns, and content richness. Match or exceed this quality.
        Do NOT copy it — use it to calibrate your output level.

        EXAMPLE START:
        \(excerpt)
        EXAMPLE END

        """
    }

    // MARK: - Visual Critique Pass (Task 1)

    private static func visualCritiquePass(
        html: String,
        screenshot: NSImage,
        prompt: String,
        designSpec: DesignSpec,
        claude: ClaudeService
    ) async throws -> String {
        let critiquePrompt = """
        This is a screenshot of a website I just built.
        Original request: "\(prompt.prefix(500))"
        Genre: \(designSpec.genre)

        Look at this screenshot carefully and identify EVERY visual problem:

        CHECK EACH:
        1. Does the hero have a real visual element (mockup, dashboard, product UI) or just text on a background?
        2. Does every section have visual depth — cards, grids, mockups — or are any sections just headline + paragraph?
        3. Are there blank, sparse, or unfinished-looking sections?
        4. Does the typography look premium with clear hierarchy (large bold headlines, size contrast)?
        5. Does the overall page feel like a $10,000 custom website or a free template?

        Then output the COMPLETE corrected HTML fixing every problem you identified.
        Start with <!DOCTYPE html>. No markdown fences. No explanation. Just the HTML.
        """

        let raw = try await claude.ask(
            prompt: critiquePrompt,
            screenshot: screenshot,
            system: "You are a world-class web designer reviewing your work. Identify visual problems and output the complete corrected HTML.",
            modelOverride: "claude-sonnet-4-6",
            maxTokensOverride: 8000
        )
        let cleaned = stripMarkdownFences(raw)
        return cleaned.lowercased().contains("<!doctype html") ? cleaned : html
    }

    // MARK: - Multi-Variant Generation (Task 4 — Studio mode)

    private static let studioVariants: [(name: String, instruction: String)] = [
        (
            name: "Modern",
            instruction: "Clean, minimal design. White or light background, dark text, one strong accent color. Tight typography. Premium SaaS-inspired aesthetic with generous whitespace."
        ),
        (
            name: "Bold",
            instruction: "Dark background, large dramatic typography, high contrast. One electric accent color. Confident, striking, editorial. Hero must be visually dramatic."
        ),
        (
            name: "Warm",
            instruction: "Warm cream or off-white background, organic feel, serif headline font, earthy accent colors. Human, approachable, and textured. Inviting aesthetic."
        )
    ]

    private static func generateVariants(
        prompt: String,
        designSpec: DesignSpec,
        referenceAnalysis: ReferenceAnalysis?,
        claude: ClaudeService
    ) async -> [(name: String, html: String, preview: NSImage?)] {

        var results: [(name: String, html: String, preview: NSImage?, order: Int)] = []

        await withTaskGroup(of: (Int, String, String, NSImage?)?.self) { group in
            for (idx, variant) in studioVariants.enumerated() {
                group.addTask {
                    let variantPrompt = prompt + "\n\nSTYLE DIRECTION FOR THIS VARIANT: \(variant.instruction)"
                    do {
                        let html = try await generateWebsite(
                            prompt: variantPrompt,
                            designSpec: designSpec,
                            referenceAnalysis: referenceAnalysis,
                            buildMode: .pro,
                            claude: claude
                        )
                        let preview = await OffscreenRenderer.capture(html: html)
                        return (idx, variant.name, html, preview)
                    } catch {
                        return nil
                    }
                }
            }
            for await result in group {
                if let r = result {
                    results.append((name: r.1, html: r.2, preview: r.3, order: r.0))
                }
            }
        }

        return results.sorted { $0.order < $1.order }.map { (name: $0.name, html: $0.html, preview: $0.preview) }
    }

    // MARK: - Structural Quality Check

    private static func structuralQualityCheck(_ html: String) -> [String] {
        var failures: [String] = []
        let lower = html.lowercased()
        if !lower.contains("<!doctype html")           { failures.append("missing DOCTYPE") }
        if !lower.contains("</html>")                  { failures.append("truncated — missing </html>") }
        if !html.contains("fonts.googleapis.com")      { failures.append("missing Google Fonts import") }
        if !html.contains("var(--")                    { failures.append("no CSS variables") }
        if !html.contains("clamp(")                    { failures.append("no fluid typography") }
        if !html.contains("@media")                    { failures.append("no responsive CSS") }
        if !html.contains("transition")                { failures.append("no hover transitions") }
        if html.components(separatedBy: "<section").count < 4 { failures.append("too few sections") }
        if lower.contains("lorem ipsum") || html.contains("Your title here") || html.contains("Coming soon") {
            failures.append("placeholder content found")
        }
        return failures
    }

    // MARK: - Targeted Repair

    private static func repairWebsite(html: String, failures: [String], prompt: String, claude: ClaudeService) async throws -> String {
        let repairPrompt = """
        This website HTML has the following structural issues:
        \(failures.map { "- \($0)" }.joined(separator: "\n"))

        Original request: "\(prompt.prefix(500))"

        Output the complete corrected HTML fixing every issue listed.
        Line 1 must be: <!DOCTYPE html>. No markdown fences, no explanation.
        """
        let repaired = try await claude.ask(
            prompt: repairPrompt,
            system: "Output only the complete corrected HTML file starting with <!DOCTYPE html>.",
            modelOverride: "claude-sonnet-4-6",
            maxTokensOverride: 8000
        )
        let cleaned = stripMarkdownFences(repaired)
        return (cleaned.lowercased().contains("<!doctype html") || cleaned.lowercased().contains("<html")) ? cleaned : html
    }

    // MARK: - Validation

    private struct ValidationResult {
        let isValid: Bool
        let html: String
        let error: String?
    }

    private static func validateAndRepair(html: String) -> ValidationResult {
        var result = html
        if !result.lowercased().contains("<!doctype") {
            return ValidationResult(isValid: false, html: result, error: "Missing DOCTYPE — generation may have been truncated. Please retry.")
        }
        if !result.lowercased().contains("</html>") {
            result += "\n</body>\n</html>"
        }
        if result.contains("<style>") && !result.contains("</style>") {
            result = result.replacingOccurrences(of: "</head>", with: "</style>\n</head>")
        }
        guard result.lowercased().contains("<html") else {
            return ValidationResult(isValid: false, html: result, error: "Output is not valid HTML.")
        }
        return ValidationResult(isValid: true, html: result, error: nil)
    }

    // MARK: - Requirements Analysis

    static func analyzeRequirements(prompt: String, claude: ClaudeService, buildMode: WebsiteBuildMode = .pro) async -> BuildReadiness {
        let analysisPrompt = """
        Analyze this website build request. Determine if there is enough information to generate a high-quality, non-generic website.

        REQUEST: "\(prompt)"

        Score criteria:
        - 90-100: Specific business name, description, audience, visual style, and content
        - 70-89: Most details present, can make reasonable assumptions
        - 40-69: Missing 2+ critical pieces
        - 0-39: Extremely vague — would produce a generic template

        Respond ONLY with valid JSON:
        {
          "score": <integer 0-100>,
          "missingRequirements": ["<specific question 1>", "<specific question 2>"],
          "assumptions": ["<assumption if proceeding>"],
          "summary": "<one sentence assessment>"
        }
        """
        do {
            let raw = try await claude.ask(
                prompt: analysisPrompt,
                system: "You are a requirements analyst. Output only JSON.",
                modelOverride: "claude-haiku-4-5-20251001",
                maxTokensOverride: 500
            )
            return parseReadiness(from: raw) ?? defaultReadiness(for: prompt)
        } catch {
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

    private static func parseReadiness(from text: String) -> BuildReadiness? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        let jsonStr = String(text[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let score   = (obj["score"] as? Double) ?? (obj["score"] as? Int).map { Double($0) } ?? 50
        let missing = obj["missingRequirements"] as? [String] ?? []
        let assume  = obj["assumptions"] as? [String] ?? []
        let summary = obj["summary"] as? String ?? "Analysis complete."
        return BuildReadiness(score: score, missingRequirements: missing, assumptions: assume, summary: summary)
    }

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
            assumptions: score >= 70 ? ["Using a modern design theme", "Marketing/landing page format"] : [],
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
        if let colonRange = prompt.range(of: "\"businessName\":"),
           let openQuote = prompt.range(of: "\"", range: colonRange.upperBound..<prompt.endIndex),
           let closeQuote = prompt.range(of: "\"", range: openQuote.upperBound..<prompt.endIndex) {
            let name = String(prompt[openQuote.upperBound..<closeQuote.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        let words = prompt.components(separatedBy: " ")
        if let forIdx = words.firstIndex(where: { $0.lowercased() == "for" }), forIdx + 1 < words.count {
            let name = words[(forIdx + 1)...].prefix(3).joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
            if !name.isEmpty { return name }
        }
        return words.prefix(4).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - Shared critic utility (accessible to improvement agent in same file)

private func runImprovementAudit(html: String, entryName: String, claude: ClaudeService) async -> CriticReport? {
    let prompt = """
    Review this website HTML and score its current quality after improvements.
    Website: \(entryName)

    Score each dimension 1–10 (10 = world-class):
    1. visualQuality — typography, polish, spacing, depth
    2. conversionPotential — CTAs, value props, trust signals
    3. mobileExperience — responsive layout, readability
    4. accessibility — contrast, semantic structure, font sizes
    5. brandConsistency — cohesive palette, consistent voice

    Respond ONLY with valid JSON — no markdown, no explanation:
    {"visualQuality":<1-10>,"conversionPotential":<1-10>,"mobileExperience":<1-10>,"accessibility":<1-10>,"brandConsistency":<1-10>,"findings":[]}

    HTML (first 10000 chars):
    \(html.prefix(10000))
    """
    do {
        let raw = try await claude.ask(
            prompt: prompt,
            system: "You are a senior UX and conversion expert. Output only JSON.",
            modelOverride: "claude-haiku-4-5-20251001",
            maxTokensOverride: 500
        )
        return WebsiteBuilderAgent.parseCriticReport(from: raw)
    } catch {
        return nil
    }
}

// MARK: - Website Improvement Agent

enum WebsiteImprovementAgent {

    static func run(jobId: UUID, outputEntryId: UUID, apiKey: String, store: AgentJobStore) async {
        let claude = ClaudeService(apiKey: apiKey)
        var stepIdx = 0

        // Step 0: Load website + critic report
        await store.updateStep(id: jobId, stepTitle: "Loading website", progress: 0.08, stepIndex: stepIdx)
        guard let entry = await OutputStore.shared.entries.first(where: { $0.id == outputEntryId }),
              let currentHTML = try? String(contentsOfFile: entry.primaryFilePath, encoding: .utf8) else {
            await store.failJob(id: jobId, error: "Could not load website. It may have been moved or deleted.")
            return
        }
        let lineCount = currentHTML.components(separatedBy: "\n").count
        await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Loaded \(lineCount) lines from \(entry.name)")

        // Try to load critic report from disk
        let criticReportPath = URL(fileURLWithPath: entry.outputDirectory)
            .appendingPathComponent("critic-report.json").path
        var criticContext = ""
        var preReport: CriticReport? = nil
        if let data = try? Data(contentsOf: URL(fileURLWithPath: criticReportPath)),
           let report = try? JSONDecoder().decode(CriticReport.self, from: data) {
            preReport = report
            criticContext = """
            QUALITY AUDIT FINDINGS (address all of these):
            Overall Score: \(report.overallScore)/10
            Visual Quality: \(report.visualQuality)/10
            Conversion Potential: \(report.conversionPotential)/10
            Mobile Experience: \(report.mobileExperience)/10
            Accessibility: \(report.accessibility)/10
            Brand Consistency: \(report.brandConsistency)/10

            SPECIFIC IMPROVEMENTS TO MAKE:
            \(report.findings.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
            """
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Quality report loaded — Score: \(report.overallScore)/10")
        } else {
            criticContext = "Improve this website's visual quality, conversion potential, mobile experience, and brand consistency."
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: "No audit report — running general quality improvement")
        }
        stepIdx += 1

        // Step 1: Generate improvements
        await store.updateStep(id: jobId, stepTitle: "Generating improvements", progress: 0.25, stepIndex: stepIdx)

        // Policy Engine consultation
        let recommendations = await PolicyEngine.shared.recommend(for: outputEntryId, jobs: store.jobs)
        let policyContext: String
        if !recommendations.isEmpty {
            let topRecs = recommendations.prefix(3)
            policyContext = "\n\nPOLICY ENGINE PRIORITY INTERVENTIONS (prioritize these above all else):\n" +
                topRecs.enumerated().map { idx, rec in
                    "\(idx + 1). \(rec.category) — expected +\(String(format: "%.1f", rec.expectedImpact)) pts (\(rec.confidence.rawValue) confidence)\n   \(rec.rationale)"
                }.joined(separator: "\n")
            await PolicyEngine.shared.logDecision(
                jobId: jobId,
                recommendedCategories: topRecs.map(\.category),
                rationale: "Pre-improvement policy consultation"
            )
            await TelemetryService.shared.track(.policyApplied(
                jobId: jobId,
                categories: topRecs.map(\.category).joined(separator: ",")
            ))
        } else {
            policyContext = ""
        }

        let improvePrompt = """
        You are a world-class web designer improving an existing website.

        \(criticContext)\(policyContext)

        CURRENT WEBSITE HTML:
        \(currentHTML.prefix(28000))

        Apply ALL the improvements listed above. Keep the same brand, business, content, and section structure.
        Focus on:
        - Elevating visual design quality (better spacing, typography hierarchy, depth)
        - Increasing conversion (stronger CTAs, clearer value props, trust signals)
        - Fixing mobile layout issues
        - Improving accessibility (contrast, font sizes, semantic HTML)
        - Strengthening brand consistency

        DO NOT change the business name, copy, or core sections — only improve the design and presentation.
        Output the COMPLETE improved HTML starting with <!DOCTYPE html>.
        No markdown fences. No explanation. Just the HTML.
        """

        let improvedHTML: String
        do {
            let raw = try await claude.ask(
                prompt: improvePrompt,
                system: "You are a world-class web designer. Output only the complete improved HTML starting with <!DOCTYPE html>.",
                modelOverride: "claude-sonnet-4-6",
                maxTokensOverride: 8000
            )
            let cleaned = stripMarkdownFences(raw)
            guard cleaned.lowercased().contains("<!doctype html") else {
                await store.failJob(id: jobId, error: "Improvement result was truncated. Please try again.")
                return
            }
            improvedHTML = cleaned
            let newLines = improvedHTML.components(separatedBy: "\n").count
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Generated \(newLines) lines")
        } catch {
            await store.failJob(id: jobId, error: "Improvement failed: \(error.localizedDescription)")
            return
        }
        stepIdx += 1

        // Step 2: Render preview + run post-improvement critic concurrently
        await store.updateStep(id: jobId, stepTitle: "Rendering preview", progress: 0.65, stepIndex: stepIdx)
        async let previewCapture = OffscreenRenderer.capture(html: improvedHTML)
        async let postAudit      = runImprovementAudit(html: improvedHTML, entryName: entry.name, claude: claude)
        let (previewImage, postReport) = await (previewCapture, postAudit)
        await store.appendLog(id: jobId, stepIndex: stepIdx, message: previewImage != nil ? "Preview rendered" : "Render skipped")
        if let post = postReport {
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Post-improvement score: \(post.overallScore)/10")
        }
        stepIdx += 1

        // Step 3: Approval
        await store.updateStep(id: jobId, stepTitle: "Awaiting approval", progress: 0.82, stepIndex: stepIdx)
        let versionNumber = entry.versions.count + 1
        let confirmation = ConfirmationRequest(
            title: "Apply improvements to \(entry.name)?",
            summary: "AI quality improvements ready.\n\nThis becomes Version \(versionNumber) of \(entry.name).",
            riskLevel: .low, approveLabel: "Apply Improvements", denyLabel: "Discard"
        )
        let approved = await store.requestConfirmation(id: jobId, request: confirmation)
        guard approved else { return }
        stepIdx += 1

        // Step 4: Save
        await store.markWriting(id: jobId)
        await store.updateStep(id: jobId, stepTitle: "Saving version", progress: 0.96, stepIndex: stepIdx)
        guard let newVersionId = await OutputStore.shared.addVersion(
            entryId: outputEntryId,
            html: improvedHTML,
            label: "Version \(versionNumber) — AI Improved",
            sourceJobId: jobId,
            editPrompt: "AI quality improvement",
            createdByAgent: "Website Improvement Agent",
            previewImage: previewImage
        ) else {
            await store.failJob(id: jobId, error: "Failed to save improved version.")
            return
        }

        await OutputStore.shared.addAssistantMessage(
            entryId: outputEntryId,
            content: "Version \(versionNumber) saved — AI quality improvements applied.",
            linkedVersionId: newVersionId
        )

        // Build delta metadata and update critic-report.json on disk
        var resultMetadata: [String: String] = ["outputDirectory": entry.outputDirectory]
        if let pre = preReport, let post = postReport {
            let deltaAvg = Double(
                (post.visualQuality - pre.visualQuality) +
                (post.conversionPotential - pre.conversionPotential) +
                (post.mobileExperience - pre.mobileExperience) +
                (post.accessibility - pre.accessibility) +
                (post.brandConsistency - pre.brandConsistency)
            ) / 5.0
            resultMetadata["preVisual"]       = "\(pre.visualQuality)"
            resultMetadata["postVisual"]      = "\(post.visualQuality)"
            resultMetadata["preConversion"]   = "\(pre.conversionPotential)"
            resultMetadata["postConversion"]  = "\(post.conversionPotential)"
            resultMetadata["preMobile"]       = "\(pre.mobileExperience)"
            resultMetadata["postMobile"]      = "\(post.mobileExperience)"
            resultMetadata["preAccessibility"]  = "\(pre.accessibility)"
            resultMetadata["postAccessibility"] = "\(post.accessibility)"
            resultMetadata["preBrand"]        = "\(pre.brandConsistency)"
            resultMetadata["postBrand"]       = "\(post.brandConsistency)"
            resultMetadata["deltaAvg"]        = String(format: "%.2f", deltaAvg)

            // Write updated critic-report.json so the next improvement has fresh baseline
            if let data = try? JSONEncoder().encode(post) {
                try? data.write(
                    to: URL(fileURLWithPath: criticReportPath),
                    options: .atomic
                )
            }
        }

        await store.completeJob(id: jobId, result: AgentJobResult(
            summary: "Version \(versionNumber) — AI quality improvements applied",
            outputPath: entry.primaryFilePath,
            previewImagePath: entry.previewImagePath,
            metadata: resultMetadata
        ))

        // Log outcome for self-improvement loop
        let allJobs = await store.jobs
        if let completedJob = allJobs.first(where: { $0.id == jobId }) {
            let detectionText = String(improvedHTML.prefix(5000)) + " " + (completedJob.result?.summary ?? "")
            let appliedCategories = CorrelationEngine.detectAllCategories(from: detectionText)
            await ControlGroupTracker.shared.record(job: completedJob, appliedCategories: appliedCategories)
            let deltaAvgActual = resultMetadata["deltaAvg"].flatMap(Double.init) ?? 0.0
            let decisionLog = await PolicyEngine.shared.decisionLog
            let lastDecision = decisionLog.first(where: { $0.jobId == jobId })
            await OutcomeEvaluator.shared.evaluate(
                jobId: jobId,
                recommendations: lastDecision,
                actualDelta: deltaAvgActual
            )
        }
    }

    private static func stripMarkdownFences(_ html: String) -> String {
        var result = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```html") { result = String(result.dropFirst(7)) }
        else if result.hasPrefix("```")  { result = String(result.dropFirst(3)) }
        if result.hasSuffix("```") { result = String(result.dropLast(3)) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Generic Agent

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

// MARK: - Website Editor Agent

enum WebsiteEditorAgent {

    static func run(jobId: UUID, outputEntryId: UUID, editRequest: String, apiKey: String, store: AgentJobStore) async {
        let claude = ClaudeService(apiKey: apiKey)
        var stepIdx = 0

        // ── Step 0: Load current HTML ─────────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Loading website", progress: 0.10, stepIndex: stepIdx)
        guard let entry = await OutputStore.shared.entries.first(where: { $0.id == outputEntryId }),
              let currentHTML = try? String(contentsOfFile: entry.primaryFilePath, encoding: .utf8) else {
            await store.failJob(id: jobId, error: "Could not load website HTML. The file may have been moved or deleted.")
            return
        }
        let lineCount = currentHTML.components(separatedBy: "\n").count
        await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Loaded \(lineCount) lines from \(entry.name)")
        stepIdx += 1

        // ── Step 1: Apply edit ────────────────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Applying edit", progress: 0.30, stepIndex: stepIdx)
        await store.appendLog(id: jobId, stepIndex: stepIdx, message: "\"\(editRequest.prefix(80))\"")

        let projectContext = buildProjectContext(entry: entry)

        let editPrompt = """
        You are editing an existing website. Apply ONLY the user's requested change.
        Preserve all other HTML, CSS, JavaScript, Google Fonts imports, CSS variables, and structure exactly.

        \(projectContext)

        CURRENT WEBSITE HTML:
        \(currentHTML.prefix(28000))

        USER EDIT REQUEST: "\(editRequest)"

        Rules:
        - Make ONLY the requested change — do NOT redesign, restructure, or regenerate the site from scratch
        - If the request references prior edits (e.g. "make it like before", "undo the typography"), use VERSION HISTORY and RECENT CONVERSATION above to understand what changed
        - If the change is cosmetic (color, font, text), modify only the affected CSS or content
        - If the change adds content, insert it cleanly without breaking existing sections
        - Preserve all :root CSS variables, class names, and the overall layout
        - Output the COMPLETE modified HTML file starting with <!DOCTYPE html>
        - No markdown fences. No explanation. Just the HTML.
        """

        let editedHTML: String
        do {
            let raw = try await claude.ask(
                prompt: editPrompt,
                system: "You are a precise web developer making targeted edits. Output only the complete modified HTML. Never redesign — only modify what was requested.",
                modelOverride: "claude-sonnet-4-6",
                maxTokensOverride: 8000
            )
            editedHTML = stripMarkdownFences(raw)
            let newLines = editedHTML.components(separatedBy: "\n").count
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Edit applied — \(newLines) lines")
        } catch {
            await store.failJob(id: jobId, error: "Edit failed: \(error.localizedDescription)")
            return
        }

        guard editedHTML.lowercased().contains("<!doctype html") else {
            await store.failJob(id: jobId, error: "Edit result was truncated. Try a more targeted request (e.g. 'change the hero headline' rather than a large structural change).")
            return
        }
        stepIdx += 1

        // ── Step 2: Render preview ────────────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Rendering preview", progress: 0.62, stepIndex: stepIdx)
        let previewImage = await OffscreenRenderer.capture(html: editedHTML)
        await store.appendLog(id: jobId, stepIndex: stepIdx, message: previewImage != nil ? "Preview rendered" : "Render skipped")
        stepIdx += 1

        // ── Step 3: Approval ──────────────────────────────────────────────────
        let versionNumber = entry.versions.count + 1
        await store.updateStep(id: jobId, stepTitle: "Awaiting approval", progress: 0.78, stepIndex: stepIdx)
        let changedSections = diffSections(before: currentHTML, after: editedHTML)
        let diffNote = changedSections.isEmpty ? "" : "\n\nChanged: \(changedSections.joined(separator: ", "))"
        let confirmation = ConfirmationRequest(
            title: "Apply edit?",
            summary: "\"\(editRequest.prefix(100))\"\(diffNote)\n\nThis becomes Version \(versionNumber) of \(entry.name).",
            riskLevel: .low,
            approveLabel: "Apply & Save",
            denyLabel: "Discard"
        )
        let approved = await store.requestConfirmation(id: jobId, request: confirmation)
        guard approved else { return }
        stepIdx += 1

        // ── Step 4: Save version ──────────────────────────────────────────────
        await store.markWriting(id: jobId)
        await store.updateStep(id: jobId, stepTitle: "Saving version", progress: 0.92, stepIndex: stepIdx)

        let versionLabel = "Version \(versionNumber)"
        guard let newVersionId = await OutputStore.shared.addVersion(
            entryId: outputEntryId,
            html: editedHTML,
            label: versionLabel,
            sourceJobId: jobId,
            editPrompt: editRequest,
            createdByAgent: "Website Editor Agent",
            previewImage: previewImage
        ) else {
            await store.failJob(id: jobId, error: "Failed to save new version to disk.")
            return
        }

        // Add assistant message summarizing what changed
        let changedNote = changedSections.isEmpty ? "" : " Changed: \(changedSections.joined(separator: ", "))."
        await OutputStore.shared.addAssistantMessage(
            entryId: outputEntryId,
            content: "\(versionLabel) saved.\(changedNote)",
            linkedVersionId: newVersionId
        )

        await store.completeJob(id: jobId, result: AgentJobResult(
            summary: "\(versionLabel) — \(editRequest.prefix(70))",
            outputPath: entry.primaryFilePath,
            previewImagePath: entry.previewImagePath,
            metadata: [
                "editRequest": editRequest,
                "versionLabel": versionLabel,
                "outputDirectory": entry.outputDirectory,
            ]
        ))

        // Background: refresh project summary every 3 versions once project has >= 5
        let updatedEntry = await OutputStore.shared.entries.first(where: { $0.id == outputEntryId })
        if let snap = updatedEntry,
           snap.versions.count >= 5,
           snap.versions.count > snap.summaryVersionCount + 2 {
            if let summary = await generateProjectSummary(entry: snap, claude: claude) {
                await OutputStore.shared.setProjectSummary(
                    entryId: outputEntryId,
                    summary: summary,
                    versionCount: snap.versions.count
                )
            }
        }
    }

    /// Builds a compact project context block.
    /// When a summary exists and version count >= 5, uses summary + last 4 versions.
    /// Otherwise uses last 8 raw versions. Always appends recent conversation.
    private static func buildProjectContext(entry: OutputEntry) -> String {
        var parts: [String] = []

        // Project identity
        let name = entry.name
        let genre = entry.metadata["genre"] ?? ""
        let style = entry.metadata["designStyle"] ?? ""
        let mode  = entry.metadata["buildMode"] ?? ""
        let identity = [genre, style, mode].filter { !$0.isEmpty }.joined(separator: " · ")
        parts.append("PROJECT CONTEXT:")
        parts.append("Site: \(name)\(identity.isEmpty ? "" : " (\(identity))")")
        parts.append("Versions: \(entry.versions.count)")

        // Use compressed summary when available (project >= 5 versions with a cached summary)
        if let summary = entry.projectSummary, entry.versions.count >= 5 {
            parts.append("")
            parts.append("PROJECT SUMMARY (from \(entry.summaryVersionCount) versions):")
            parts.append(summary)
            parts.append("")
            parts.append("RECENT VERSIONS (last 4):")
            for version in Array(entry.versions.dropFirst().suffix(4)) {
                let prompt = version.editPrompt.map { "\"\($0.prefix(90))\"" } ?? "—"
                parts.append("  \(version.label): \(prompt)")
            }
        } else {
            // Raw history — last 8 edit versions
            let editVersions = Array(entry.versions.dropFirst().suffix(8))
            if !editVersions.isEmpty {
                parts.append("")
                parts.append("VERSION HISTORY (chronological, most recent last):")
                for version in editVersions {
                    let prompt = version.editPrompt.map { "\"\($0.prefix(90))\"" } ?? "—"
                    let agent: String
                    switch version.createdByAgent {
                    case "Website Builder Agent": agent = "Builder"
                    case "Website Editor Agent":  agent = "Editor"
                    case "Restore":               agent = "Restore"
                    default:                      agent = version.createdByAgent ?? "—"
                    }
                    parts.append("  \(version.label): \(prompt) [\(agent)]")
                }
            }
        }

        // Recent conversation — last 6 messages
        let recent = Array(entry.editHistory.suffix(6))
        if !recent.isEmpty {
            parts.append("")
            parts.append("RECENT CONVERSATION (most recent last):")
            for msg in recent {
                let role = msg.role == .user ? "User" : "Mira"
                parts.append("  \(role): \"\(msg.content.prefix(120))\"")
            }
        }

        return parts.joined(separator: "\n")
    }

    /// Generates a compressed project summary from the full version history.
    /// Called in background after each edit when version count >= 5.
    static func generateProjectSummary(entry: OutputEntry, claude: ClaudeService) async -> String? {
        let allEdits = entry.versions.dropFirst()
        guard !allEdits.isEmpty else { return nil }

        let historyText = allEdits.map { v in
            "  \(v.label): \(v.editPrompt.map { "\"\($0.prefix(80))\"" } ?? "—")"
        }.joined(separator: "\n")

        let prompt = """
        Website edit history to summarize:

        Site: \(entry.name)
        Genre: \(entry.metadata["genre"] ?? "unknown") · Style: \(entry.metadata["designStyle"] ?? "unknown")

        \(historyText)

        Write a compact PROJECT SUMMARY with these sections:

        Design evolution:
        • [3-5 bullets describing the major changes in plain language]

        Current design language: [5-7 descriptive terms separated by · ]

        Key sections: [comma-separated list of the main website sections]

        Known preferences:
        • [2-4 bullets describing repeating stylistic patterns the user keeps requesting — e.g. "Prefers Apple-inspired spacing", "Consistently requests high contrast CTAs", "Avoids glassmorphism effects"]
        Omit this section entirely if fewer than 3 edits or no clear patterns exist.

        Under 220 words. Output only the summary — no preamble, no title.
        """

        do {
            return try await claude.ask(
                prompt: prompt,
                system: "You are a design historian. Write concise, accurate summaries of website evolution. Output only the summary sections.",
                modelOverride: "claude-haiku-4-5-20251001",
                maxTokensOverride: 500
            )
        } catch {
            return nil
        }
    }

    /// Extracts named sections from HTML and returns those that differ between before and after.
    /// Uses the step title from `<section id/class>`, `<nav>`, and `<footer>` tags.
    private static func diffSections(before: String, after: String) -> [String] {
        func extractSections(_ html: String) -> [String: String] {
            var map: [String: String] = [:]
            // Match block-level elements: nav, footer, section with id or class
            let pattern = #"(<(?:nav|footer|section)[^>]*>)([\s\S]*?)(?=<(?:nav|footer|section)|</body>|$)"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return map }
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let match, let tagRange = Range(match.range(at: 1), in: html) else { return }
                let tag = String(html[tagRange]).lowercased()
                let key: String
                if let idMatch = tag.range(of: #"id="([^"]+)""#, options: .regularExpression) {
                    key = String(tag[idMatch]).replacingOccurrences(of: #"id="|""#, with: "", options: .regularExpression)
                } else if let classMatch = tag.range(of: #"class="([^"]+)""#, options: .regularExpression) {
                    let raw = String(tag[classMatch]).replacingOccurrences(of: #"class="|""#, with: "", options: .regularExpression)
                    key = raw.components(separatedBy: " ").first ?? raw
                } else if tag.hasPrefix("<nav") {
                    key = "nav"
                } else if tag.hasPrefix("<footer") {
                    key = "footer"
                } else {
                    key = tag
                }
                if let bodyRange = Range(match.range(at: 2), in: html) {
                    map[key] = String(html[bodyRange])
                }
            }
            return map
        }

        let beforeSections = extractSections(before)
        let afterSections  = extractSections(after)

        var changed: [String] = []
        for (key, afterContent) in afterSections {
            if beforeSections[key] != afterContent {
                let label = key.prefix(1).uppercased() + key.dropFirst()
                changed.append(label)
            }
        }
        return changed.prefix(6).map { $0 }
    }

    private static func stripMarkdownFences(_ html: String) -> String {
        var result = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```html") { result = String(result.dropFirst(7)) }
        else if result.hasPrefix("```")  { result = String(result.dropFirst(3)) }
        if result.hasSuffix("```") { result = String(result.dropLast(3)) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
