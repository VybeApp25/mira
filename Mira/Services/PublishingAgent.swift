import Foundation

enum PublishingAgent {

    // MARK: - Target

    enum PublishTarget: String, CaseIterable, Identifiable {
        case vercel      = "vercel"
        case netlify     = "netlify"
        case githubPages = "github"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .vercel:      return "Vercel"
            case .netlify:     return "Netlify"
            case .githubPages: return "GitHub Pages"
            }
        }

        var icon: String {
            switch self {
            case .vercel:      return "triangle.fill"
            case .netlify:     return "bolt.fill"
            case .githubPages: return "chevron.left.forwardslash.chevron.right"
            }
        }

        var composioSlug: String { rawValue }
    }

    // MARK: - Run

    static func run(
        jobId: UUID,
        outputEntryId: UUID,
        target: PublishTarget,
        apiKey: String,
        store: AgentJobStore
    ) async {
        var stepIdx = 0

        // ── Step 0: Validate website ──────────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Validating website", progress: 0.08, stepIndex: stepIdx)

        guard let entry = await OutputStore.shared.entries.first(where: { $0.id == outputEntryId }),
              let html = try? String(contentsOfFile: entry.primaryFilePath, encoding: .utf8),
              html.lowercased().contains("<!doctype html") else {
            await store.failJob(id: jobId, error: "Website file is missing or invalid. Rebuild the site first.")
            return
        }

        let lineCount = html.components(separatedBy: "\n").count
        await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Validated — \(lineCount) lines · \(entry.name)")
        stepIdx += 1

        // ── Step 1: Check Composio connection ────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Checking \(target.displayName) connection", progress: 0.18, stepIndex: stepIdx)

        let agentHealthy = await AgentService.shared.checkHealth()
        guard agentHealthy else {
            await store.markBlockedTool(id: jobId, reason: "Agent service is not running.\n\nStart it with:\ncd Mira/AgentService && npm start")
            return
        }

        let connected: [String]
        do {
            connected = try await AgentService.shared.connections()
        } catch {
            await store.failJob(id: jobId, error: "Could not check Composio connections: \(error.localizedDescription)")
            return
        }

        guard connected.contains(target.composioSlug) else {
            await store.markBlockedTool(
                id: jobId,
                reason: "\(target.displayName) is not connected.\n\nGo to Settings → Integrations to connect your \(target.displayName) account, then retry this job."
            )
            return
        }

        await store.appendLog(id: jobId, stepIndex: stepIdx, message: "\(target.displayName) connected ✓")
        stepIdx += 1

        // ── Step 2: Approval gate ─────────────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Awaiting approval", progress: 0.28, stepIndex: stepIdx)

        let versionLabel = entry.versions.last?.label ?? "Version \(entry.versions.count)"
        let alreadyPublished = entry.publishedUrl != nil
        let confirmation = ConfirmationRequest(
            title: alreadyPublished ? "Republish \(entry.name)?" : "Publish \(entry.name)?",
            summary: "\(versionLabel) of \"\(entry.name)\" will be deployed to \(target.displayName) via Composio.\(alreadyPublished ? "\n\nThis will overwrite the existing deployment." : "\n\nA live URL will be saved to this project.")",
            riskLevel: alreadyPublished ? .medium : .low,
            approveLabel: alreadyPublished ? "Republish" : "Deploy",
            denyLabel: "Cancel"
        )
        let approved = await store.requestConfirmation(id: jobId, request: confirmation)
        guard approved else { return }
        stepIdx += 1

        // ── Step 3: Package files ─────────────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Packaging files", progress: 0.42, stepIndex: stepIdx)
        await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Reading \(entry.outputDirectory)")

        // Trim HTML to fit in prompt — Composio agent uses natural language
        let htmlContent = String(html.prefix(60000))
        let siteName = entry.name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        stepIdx += 1

        // ── Step 4: Invoke Composio deployment ────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Deploying to \(target.displayName)", progress: 0.58, stepIndex: stepIdx)

        let deployPrompt = buildDeployPrompt(target: target, siteName: siteName, html: htmlContent, entryName: entry.name)

        let response: AgentResponse
        do {
            response = try await AgentService.shared.run(prompt: deployPrompt, accessToken: SupabaseService.cachedAccessToken)
            await store.appendLog(id: jobId, stepIndex: stepIdx, message: "Composio action executed")
        } catch {
            await store.failJob(id: jobId, error: "Deployment failed: \(error.localizedDescription)\n\nCheck that the Agent service is running and \(target.displayName) is connected.")
            return
        }
        stepIdx += 1

        // ── Step 5: Wait and extract URL ──────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Confirming deployment", progress: 0.80, stepIndex: stepIdx)

        guard let deployedURL = extractDeployURL(from: response.reply) else {
            await store.failJob(
                id: jobId,
                error: "Deployment may have succeeded but no URL was returned.\n\nCheck your \(target.displayName) dashboard.\n\nAgent response:\n\(String(response.reply.prefix(300)))"
            )
            return
        }

        await store.appendLog(id: jobId, stepIndex: stepIdx, message: "URL: \(deployedURL)")
        stepIdx += 1

        // ── Step 6: Store result ──────────────────────────────────────────────
        await store.updateStep(id: jobId, stepTitle: "Saving deployment", progress: 0.95, stepIndex: stepIdx)

        await OutputStore.shared.updatePublishing(
            entryId: outputEntryId,
            url: deployedURL,
            provider: target.displayName,
            status: "live"
        )

        await store.completeJob(id: jobId, result: AgentJobResult(
            summary: "Deployed \(entry.name) → \(deployedURL)",
            outputPath: entry.primaryFilePath,
            previewImagePath: entry.previewImagePath,
            metadata: [
                "publishedUrl":       deployedURL,
                "deploymentProvider": target.displayName,
                "siteName":           entry.name,
            ]
        ))
    }

    // MARK: - Deploy Prompt Builder

    private static func buildDeployPrompt(target: PublishTarget, siteName: String, html: String, entryName: String) -> String {
        switch target {
        case .vercel:
            return """
            Deploy a single-page website to Vercel using the Vercel API tools.

            Project name: \(siteName)
            Display name: \(entryName)

            Website content — this is the complete index.html:
            \(html)

            Steps:
            1. Create a new Vercel deployment with this HTML as the content of index.html
            2. Wait for the deployment to complete
            3. Return the deployment URL (*.vercel.app or custom domain)
            """

        case .netlify:
            return """
            Deploy a single-page website to Netlify using the Netlify API tools.

            Site name: \(siteName)
            Display name: \(entryName)

            Website content — this is the complete index.html:
            \(html)

            Steps:
            1. Create a new Netlify site (or deploy to existing \(siteName) if it exists)
            2. Deploy this HTML file as index.html
            3. Return the live URL (*.netlify.app or custom domain)
            """

        case .githubPages:
            return """
            Deploy a website to GitHub Pages using the GitHub API tools.

            Repository name: \(siteName)-site
            Display name: \(entryName)

            Website content — this is the complete index.html:
            \(html)

            Steps:
            1. Create the repository \(siteName)-site if it doesn't exist (set it to public)
            2. Create or update index.html in the main branch with this HTML content
            3. Enable GitHub Pages on the main branch (/ root folder)
            4. Return the GitHub Pages URL (https://username.github.io/\(siteName)-site)
            """
        }
    }

    // MARK: - URL Extraction

    private static func extractDeployURL(from text: String) -> String? {
        // Prefer deployment-specific URLs first
        let patterns = [
            #"https?://[a-zA-Z0-9][a-zA-Z0-9\-\.]*\.vercel\.app[^\s\)\"\'<>,]*"#,
            #"https?://[a-zA-Z0-9][a-zA-Z0-9\-\.]*\.netlify\.app[^\s\)\"\'<>,]*"#,
            #"https?://[a-zA-Z0-9][a-zA-Z0-9\-\.]*\.github\.io[^\s\)\"\'<>,]*"#,
            #"https?://[a-zA-Z0-9][a-zA-Z0-9\-\.]+\.[a-zA-Z]{2,}[^\s\)\"\'<>,]*"#,
        ]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                return String(text[range])
            }
        }
        return nil
    }
}
