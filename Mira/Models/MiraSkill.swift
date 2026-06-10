import Foundation

// MARK: - Model

struct MiraSkill: Identifiable, Hashable {
    let id:       String
    let name:     String
    let tagline:  String     // one-liner shown on card
    let icon:     String     // SF Symbol name
    let category: Category
    let context:  String     // injected into Claude system prompt when active

    enum Category: String, CaseIterable {
        case productivity  = "Productivity"
        case engineering   = "Engineering"
        case communication = "Communication"
        case creative      = "Creative"

        var icon: String {
            switch self {
            case .productivity:  return "briefcase.fill"
            case .engineering:   return "terminal.fill"
            case .communication: return "bubble.left.and.bubble.right.fill"
            case .creative:      return "paintpalette.fill"
            }
        }
    }
}

// MARK: - Catalog

enum MiraSkillCatalog {
    static let all: [MiraSkill] = [

        // MARK: Productivity

        MiraSkill(
            id: "artifacts",
            name: "File Finder",
            tagline: "Open, reveal & organise generated files",
            icon: "folder.fill",
            category: .productivity,
            context: """
                Skill active: File Finder.
                When finding/opening files: search likely output roots first (current project dir, Desktop, Downloads). Verify the file exists with nonzero size before reporting. Always end with the absolute path. Do not overwrite files without confirmation.
                """
        ),

        MiraSkill(
            id: "research-report",
            name: "Research Report",
            tagline: "Web research → Markdown or PDF",
            icon: "doc.magnifyingglass.fill",
            category: .productivity,
            context: """
                Skill active: Research Report.
                For research tasks: search multiple sources, synthesise findings, cite URLs. Deliver a structured Markdown document by default; offer PDF or DOCX when the user requests a shareable artifact. Bias toward verified facts over summaries.
                """
        ),

        MiraSkill(
            id: "google-workspace",
            name: "Google Workspace",
            tagline: "Gmail, Calendar, Drive via Composio",
            icon: "envelope.badge.fill",
            category: .productivity,
            context: """
                Skill active: Google Workspace.
                Prefer the Composio MCP route for Gmail, Calendar, Drive, Docs, and Sheets. For email sends, draft first and show recipient/subject/body summary — require explicit "send it" approval before transmitting. Never delete or archive without confirmation.
                """
        ),

        MiraSkill(
            id: "spreadsheet",
            name: "Spreadsheet",
            tagline: "Create & edit Excel / CSV files",
            icon: "tablecells.fill",
            category: .productivity,
            context: """
                Skill active: Spreadsheet.
                Use Python (openpyxl, pandas) for .xlsx/.csv work. Verify the output with a row-count or column-check after writing. Provide the absolute path to the finished file.
                """
        ),

        // MARK: Engineering

        MiraSkill(
            id: "repo-operator",
            name: "Repo Operator",
            tagline: "Git, GitHub PRs, CI, code review",
            icon: "chevron.left.forwardslash.chevron.right",
            category: .engineering,
            context: """
                Skill active: Repo Operator.
                For git/GitHub work: check status before any destructive action. Use the `gh` CLI for PRs and issues. Prefer `gh pr create` over manual curl. Always run tests or lint before suggesting a commit.
                """
        ),

        MiraSkill(
            id: "dev-setup-doctor",
            name: "Dev Setup Doctor",
            tagline: "Fix env, MCP, API keys, localhost",
            icon: "wrench.and.screwdriver.fill",
            category: .engineering,
            context: """
                Skill active: Dev Setup Doctor.
                Diagnose before changing: check versions, env files, running processes, and logs first. Explain the failure in plain language, then apply the smallest safe fix. Do not overwrite .env files or touch production services without confirmation.
                """
        ),

        MiraSkill(
            id: "vercel-deploy",
            name: "Vercel Deploy",
            tagline: "Deploy sites live with a Vercel URL",
            icon: "cloud.fill",
            category: .engineering,
            context: """
                Skill active: Vercel Deploy.
                Use the Vercel CLI (`vercel` or `npx vercel`). For production deploys use `--prod`. Always report the final deployment URL. If the project has no `vercel.json`, create a minimal one.
                """
        ),

        MiraSkill(
            id: "build-preview",
            name: "Build & Preview",
            tagline: "Websites, apps, dashboards with live preview",
            icon: "macwindow",
            category: .engineering,
            context: """
                Skill active: Build & Preview.
                Prefer a single self-contained HTML file when possible. Only spin up a dev server for multi-route/framework projects. Start servers detached (nohup/disown), poll until responding before reporting the URL. Never hand back a URL you have not verified is live.
                """
        ),

        // MARK: Communication

        MiraSkill(
            id: "email-assistant",
            name: "Email Assistant",
            tagline: "Draft, rewrite, triage & send emails",
            icon: "envelope.fill",
            category: .communication,
            context: """
                Skill active: Email Assistant.
                For outbound email: draft first, show a summary of recipient/subject/body, and wait for explicit send approval. For triage: summarise thread, suggest reply, do not send without approval. Use Composio Gmail tools when available.
                """
        ),

        MiraSkill(
            id: "pdf",
            name: "PDF Skill",
            tagline: "Read, create & extract from PDFs",
            icon: "doc.fill",
            category: .communication,
            context: """
                Skill active: PDF.
                Use Python: pdfplumber or pymupdf for reading/extraction; reportlab or fpdf2 for generation. Render a representative page to verify visual fidelity before delivering. Provide the absolute output path.
                """
        ),

        MiraSkill(
            id: "docs",
            name: "Document Editor",
            tagline: "Create & edit .docx with formatting",
            icon: "doc.richtext.fill",
            category: .communication,
            context: """
                Skill active: Document Editor.
                Use python-docx for .docx creation and editing. Preserve existing styles when editing. Verify page/paragraph count after writing. Deliver the absolute file path.
                """
        ),

        // MARK: Creative

        MiraSkill(
            id: "creative-studio",
            name: "Creative Studio",
            tagline: "Design, brand, frontend polish",
            icon: "paintpalette.fill",
            category: .creative,
            context: """
                Skill active: Creative Studio.
                Route creative work to the best available medium: build-preview/frontend-design for UI, pdf/doc for documents, Markdown for outlines. Provider-backed image, video, or slide generation is not shipped — offer a document or frontend alternative instead. Keep real text in code/document layers, not baked into images.
                """
        ),
    ]
}
