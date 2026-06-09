import Foundation
import AppKit

// MARK: - Website Health Agent

enum WebsiteHealthAgent {

    static func run(jobId: UUID, outputEntryId: UUID, apiKey: String, store: AgentJobStore) async {
        let claude = ClaudeService(apiKey: apiKey)

        // ── Step 0: Load website ─────────────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Loading website", progress: 0.10, stepIndex: 0)

        guard let entry = await MainActor.run(body: { OutputStore.shared.entries.first { $0.id == outputEntryId } }) else {
            await store.failJob(id: jobId, error: "Output entry not found")
            return
        }

        guard let html = try? String(contentsOfFile: entry.primaryFilePath, encoding: .utf8) else {
            await store.failJob(id: jobId, error: "Could not read website file")
            return
        }

        let currentVersion = entry.versions.count

        // ── Step 1: SEO analysis ─────────────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "SEO analysis", progress: 0.28, stepIndex: 1)
        let seoResult = analyzeSEO(html)

        // ── Step 2: Accessibility check ──────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Accessibility check", progress: 0.46, stepIndex: 2)
        let a11yResult = analyzeAccessibility(html)

        // ── Step 3: Mobile & UX check ────────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Mobile & UX check", progress: 0.62, stepIndex: 3)
        let mobileResult = analyzeMobile(html)

        var allFindings = seoResult.findings + a11yResult.findings + mobileResult.findings

        // ── Step 4: AI recommendations ───────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "AI recommendations", progress: 0.80, stepIndex: 4)
        if let aiInsight = await enrichFindings(
            html: html,
            seo: seoResult.score,
            a11y: a11yResult.score,
            mobile: mobileResult.score,
            findings: allFindings,
            entry: entry,
            claude: claude
        ) {
            // Parse bullet points from the AI response and add as suggestion findings
            let lines = aiInsight.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var suggestionCount = 0
            for line in lines {
                guard suggestionCount < 3 else { break }
                // Accept lines starting with bullet characters or numbered
                var text = line
                for prefix in ["•", "-", "*", "1.", "2.", "3.", "1)", "2)", "3)"] {
                    if text.hasPrefix(prefix) {
                        text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
                if text.isEmpty { continue }
                allFindings.append(HealthFinding(category: "AI", severity: .suggestion, message: text))
                suggestionCount += 1
            }
        }

        // ── Step 5: Save report ──────────────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Saving report", progress: 0.94, stepIndex: 5)

        let avg = (seoResult.score + a11yResult.score + mobileResult.score) / 3
        let report = WebsiteHealthReport(
            overallScore: avg,
            traffic: nil,
            conversions: nil,
            mobileUX: mobileResult.score,
            seo: seoResult.score,
            accessibility: a11yResult.score,
            findings: allFindings,
            analyzedAt: Date(),
            analyzedVersion: currentVersion
        )

        await MainActor.run {
            OutputStore.shared.setHealthReport(id: outputEntryId, report: report)
        }

        let criticalCount = allFindings.filter { $0.severity == .critical }.count
        let warnCount     = allFindings.filter { $0.severity == .warning  }.count
        let totalFindings = allFindings.count
        let summary = "Health Score: \(avg)/100 · \(totalFindings) finding\(totalFindings == 1 ? "" : "s") · SEO:\(seoResult.score) Access:\(a11yResult.score) Mobile:\(mobileResult.score)\(criticalCount > 0 ? " · \(criticalCount) critical" : "")\(warnCount > 0 ? " · \(warnCount) warnings" : "")"

        await store.completeJob(id: jobId, result: AgentJobResult(
            summary: summary,
            outputPath: entry.primaryFilePath,
            previewImagePath: entry.previewImagePath,
            metadata: ["healthScore": "\(avg)", "findings": "\(totalFindings)"]
        ))
    }

    // MARK: - SEO Analysis (pure, 100 pts)

    private static func analyzeSEO(_ html: String) -> (score: Int, findings: [HealthFinding]) {
        var score = 0
        var findings: [HealthFinding] = []
        let lower = html.lowercased()

        // Has <title tag: +20
        if lower.contains("<title") {
            score += 20
            // Title length 20-70 chars: +15
            if let range = lower.range(of: "<title[^>]*>(.*?)</title>", options: .regularExpression),
               let content = extractContent(from: html, pattern: "<title[^>]*>(.*?)</title>") {
                let _ = range
                let len = content.count
                if len >= 20 && len <= 70 {
                    score += 15
                } else if len < 20 {
                    findings.append(HealthFinding(category: "SEO", severity: .warning, message: "Title tag is too short (\(len) chars). Aim for 20-70 characters."))
                } else {
                    findings.append(HealthFinding(category: "SEO", severity: .warning, message: "Title tag is too long (\(len) chars). Keep it under 70 characters to avoid truncation in search results."))
                }
            } else {
                findings.append(HealthFinding(category: "SEO", severity: .warning, message: "Title tag content could not be read. Ensure it has visible text."))
            }
        } else {
            findings.append(HealthFinding(category: "SEO", severity: .critical, message: "Missing <title> tag. Search engines rely on it as the page headline in results."))
        }

        // Has <meta name="description": +20
        if lower.contains("<meta") && lower.contains("name=\"description\"") || lower.contains("name='description'") {
            score += 20
            // Description 80-160 chars: +10
            if let desc = extractMetaContent(from: html, name: "description") {
                let len = desc.count
                if len >= 80 && len <= 160 {
                    score += 10
                } else if len < 80 {
                    findings.append(HealthFinding(category: "SEO", severity: .warning, message: "Meta description is short (\(len) chars). Expand to 80-160 characters for better CTR."))
                } else {
                    findings.append(HealthFinding(category: "SEO", severity: .suggestion, message: "Meta description is long (\(len) chars). Trim to under 160 characters to prevent truncation."))
                }
            }
        } else {
            findings.append(HealthFinding(category: "SEO", severity: .critical, message: "Missing meta description. Add <meta name=\"description\" content=\"...\"> to improve click-through rate from search results."))
        }

        // Has <h1: +15
        if lower.contains("<h1") {
            score += 15
            // h1 appears only once: +10
            let h1Count = countOccurrences(of: "<h1", in: lower)
            if h1Count == 1 {
                score += 10
            } else {
                findings.append(HealthFinding(category: "SEO", severity: .warning, message: "Multiple <h1> tags found (\(h1Count)). Each page should have exactly one <h1> for clear hierarchy."))
            }
        } else {
            findings.append(HealthFinding(category: "SEO", severity: .critical, message: "Missing <h1> tag. Add a primary heading to establish page hierarchy for search engines."))
        }

        // Has alt= on <img tags: +10
        let imgCount = countOccurrences(of: "<img", in: lower)
        if imgCount > 0 {
            let altCount = countOccurrences(of: " alt=", in: lower)
            if altCount >= imgCount {
                score += 10
            } else {
                findings.append(HealthFinding(category: "SEO", severity: .warning, message: "\(imgCount - altCount) of \(imgCount) images are missing alt attributes. Alt text improves both SEO and accessibility."))
            }
        } else {
            score += 10
        }

        return (score: min(score, 100), findings: findings)
    }

    // MARK: - Accessibility Analysis (pure, 100 pts)

    private static func analyzeAccessibility(_ html: String) -> (score: Int, findings: [HealthFinding]) {
        var score = 0
        var findings: [HealthFinding] = []
        let lower = html.lowercased()

        // <html has lang=: +25
        if lower.contains("<html") && (lower.contains(" lang=") || lower.contains("\tlang=")) {
            score += 25
        } else {
            findings.append(HealthFinding(category: "Accessibility", severity: .critical, message: "Missing lang attribute on <html> element. Screen readers need it to use the correct language."))
        }

        // All <img tags have non-empty alt: +25
        let imgCount = countOccurrences(of: "<img", in: lower)
        if imgCount > 0 {
            let emptyAlt = countOccurrences(of: "alt=\"\"", in: lower) + countOccurrences(of: "alt=''", in: lower)
            let missingAlt = imgCount - countOccurrences(of: " alt=", in: lower)
            if missingAlt == 0 && emptyAlt == 0 {
                score += 25
            } else {
                let bad = missingAlt + emptyAlt
                findings.append(HealthFinding(category: "Accessibility", severity: .critical, message: "\(bad) image\(bad == 1 ? "" : "s") missing meaningful alt text. Add descriptive alt attributes for screen reader users."))
            }
        } else {
            score += 25
        }

        // No <button without text content (approximate): +20
        let buttonCount = countOccurrences(of: "<button", in: lower)
        if buttonCount > 0 {
            // Check for icon-only buttons (containing only svg/img with no text nearby)
            let ariaLabel = countOccurrences(of: "aria-label=", in: lower)
            let ariaLabelledby = countOccurrences(of: "aria-labelledby=", in: lower)
            if ariaLabel + ariaLabelledby >= buttonCount {
                score += 20
            } else {
                score += 20
                // Only flag if there appear to be many more buttons than aria labels
                if buttonCount > (ariaLabel + ariaLabelledby + 2) {
                    findings.append(HealthFinding(category: "Accessibility", severity: .warning, message: "Some buttons may lack accessible labels. Add aria-label to icon-only buttons for screen reader users."))
                    score -= 20
                }
            }
        } else {
            score += 20
        }

        // Has <main landmark: +15
        if lower.contains("<main") {
            score += 15
        } else {
            findings.append(HealthFinding(category: "Accessibility", severity: .warning, message: "Missing <main> landmark. Screen reader users rely on landmarks to navigate the page structure."))
        }

        // No text with font-size under 12px: +15
        var hasSmallText = false
        // Look for inline font-size patterns like font-size: 9px or font-size:10px
        let pattern = "font-size:\\s*([0-9]+)px"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(html.startIndex..., in: html)
            let matches = regex.matches(in: html, range: range)
            for match in matches {
                if match.numberOfRanges > 1,
                   let sizeRange = Range(match.range(at: 1), in: html),
                   let size = Int(html[sizeRange]),
                   size < 12 {
                    hasSmallText = true
                    break
                }
            }
        }
        if hasSmallText {
            findings.append(HealthFinding(category: "Accessibility", severity: .warning, message: "Text smaller than 12px detected. Use minimum 16px body text for readability and WCAG compliance."))
        } else {
            score += 15
        }

        return (score: min(score, 100), findings: findings)
    }

    // MARK: - Mobile / UX Analysis (pure, 100 pts)

    private static func analyzeMobile(_ html: String) -> (score: Int, findings: [HealthFinding]) {
        var score = 0
        var findings: [HealthFinding] = []
        let lower = html.lowercased()

        // Has <meta name="viewport": +30
        if (lower.contains("name=\"viewport\"") || lower.contains("name='viewport'")) {
            score += 30
        } else {
            findings.append(HealthFinding(category: "Mobile", severity: .critical, message: "Missing viewport meta tag. Add <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"> for proper mobile rendering."))
        }

        // Has @media in CSS: +30
        if lower.contains("@media") {
            score += 30
        } else {
            findings.append(HealthFinding(category: "Mobile", severity: .critical, message: "No CSS @media queries found. Add responsive breakpoints to ensure the layout adapts to different screen sizes."))
        }

        // Uses clamp( OR vw OR % units: +20
        if lower.contains("clamp(") || lower.contains("vw") || lower.contains("vh") || lower.contains("%") {
            score += 20
        } else {
            findings.append(HealthFinding(category: "Mobile", severity: .suggestion, message: "No fluid units (clamp, vw, %) found. Use fluid typography and spacing for a smoother responsive experience."))
        }

        // Has max-width or min-width in CSS: +20
        if lower.contains("max-width") || lower.contains("min-width") {
            score += 20
        } else {
            findings.append(HealthFinding(category: "Mobile", severity: .suggestion, message: "No max-width or min-width constraints found. Add them to prevent the layout from becoming too wide on large screens."))
        }

        return (score: min(score, 100), findings: findings)
    }

    // MARK: - AI Enrichment

    private static func enrichFindings(
        html: String,
        seo: Int,
        a11y: Int,
        mobile: Int,
        findings: [HealthFinding],
        entry: OutputEntry,
        claude: ClaudeService
    ) async -> String? {
        let findingSummary = findings.prefix(8).map { "[\($0.severity.rawValue.uppercased())] \($0.category): \($0.message)" }.joined(separator: "\n")
        let htmlSnippet = String(html.prefix(4000))
        let prompt = """
        You are a web performance expert. Analyze this website and provide the top 3 most impactful improvement recommendations.

        Current scores: SEO \(seo)/100, Accessibility \(a11y)/100, Mobile UX \(mobile)/100
        Site name: \(entry.name)

        Detected issues:
        \(findingSummary.isEmpty ? "None" : findingSummary)

        HTML snippet (first 4000 chars):
        \(htmlSnippet)

        Respond with exactly 3 actionable recommendations, one per line, starting each with a bullet (•). Be specific to this website's actual content and structure. Focus on the highest-impact improvements.
        """

        return try? await claude.ask(
            prompt: prompt,
            system: "You are a concise web performance expert. Give exactly 3 bullet-point recommendations.",
            modelOverride: "claude-haiku-4-5-20251001",
            maxTokensOverride: 300
        )
    }

    // MARK: - HTML Parsing Helpers

    private static func countOccurrences(of substring: String, in string: String) -> Int {
        var count = 0
        var searchRange = string.startIndex..<string.endIndex
        while let range = string.range(of: substring, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<string.endIndex
        }
        return count
    }

    private static func extractContent(from html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1,
              let contentRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractMetaContent(from html: String, name: String) -> String? {
        // Match <meta name="description" content="..."> in either attribute order
        let patterns = [
            "<meta[^>]*name=[\"']\(name)[\"'][^>]*content=[\"']([^\"']*)[\"'][^>]*>",
            "<meta[^>]*content=[\"']([^\"']*)[\"'][^>]*name=[\"']\(name)[\"'][^>]*>"
        ]
        for pattern in patterns {
            if let content = extractContent(from: html, pattern: pattern) {
                return content
            }
        }
        return nil
    }
}
