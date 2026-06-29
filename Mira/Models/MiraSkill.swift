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
                To read: run_python_skill(skill:"sheet_rw", args:{op:"read", path:"<abs_path>", sheet?:"<name>"}).
                To write: run_python_skill(skill:"sheet_rw", args:{op:"write", path:"<abs_path>", headers:["Col1",...], rows:[[val,...],...]}).
                To append a row: run_python_skill(skill:"sheet_rw", args:{op:"append", path:"<abs_path>", row:[val,...]}).
                To convert CSV to XLSX: args:{op:"csv_to_xlsx", csv_path:"...", xlsx_path:"..."}.
                Confirm row_count in the result. Provide the absolute output path.
                """
        ),

        MiraSkill(
            id: "frontend-design",
            name: "Frontend Design",
            tagline: "Build & polish UI, layouts, animations",
            icon: "sparkles.rectangle.stack.fill",
            category: .engineering,
            context: """
                Skill active: Frontend Design.
                Build or improve frontend UI: websites, web apps, dashboards, landing pages, components, and HTML prototypes.
                Rules: use semantic HTML5 + CSS3; default to mobile-first responsive layout; use CSS custom properties for theme tokens; JS in a single <script defer> block; no CDN links without asking.
                Visual quality bar: visual hierarchy via size/weight/color contrast; generous white space; no lorem ipsum in delivered output; smooth micro-interactions (CSS transitions, not JS animation libraries).
                Typography: system font stack first; max 3 font sizes per component; line-height 1.5 for body.
                Color: define a 5-shade palette with a primary, accent, neutral, success, and error token; ensure WCAG AA contrast for text.
                Animation: transitions 150–300ms ease-in-out; avoid motion for purely decorative elements.
                Do not use Computer Use to visually verify artifacts — check output with local renders, file checks, or build logs.
                """
        ),

        // MARK: Engineering

        MiraSkill(
            id: "gpt4",
            name: "GPT-4o",
            tagline: "Ask OpenAI GPT-4o for a second opinion",
            icon: "brain.head.profile",
            category: .engineering,
            context: """
                Skill active: GPT-4o.
                Use ask_gpt(prompt:"<question>", model?:"gpt-4o"|"gpt-4o-mini") to query OpenAI's GPT-4o.
                Use gpt-4o-mini for fast cheap lookups; gpt-4o for thorough reasoning.
                Present the response with a header "GPT-4o says:" so the user knows which model answered.
                Falls back gracefully if the OpenAI key is not configured.
                """
        ),

        MiraSkill(
            id: "presentations",
            name: "Presentations",
            tagline: "Build .pptx slide decks with python-pptx",
            icon: "rectangle.on.rectangle.fill",
            category: .productivity,
            context: """
                Skill active: Presentations.
                To create a deck: run_python_skill(skill:"pptx_rw", args:{op:"create", path:"~/Desktop/<name>.pptx", title?:"<deck title>", slides:[{title:"<slide title>", bullets:["point 1","point 2"], layout?"title_content"}]}).
                Layouts: "title" (title-only slide), "title_content" (default), "blank".
                To read: run_python_skill(skill:"pptx_rw", args:{op:"read", path:"<abs_path>"}).
                To add a slide: run_python_skill(skill:"pptx_rw", args:{op:"append_slide", path:"<abs_path>", title:"<title>", bullets:["..."]}).
                Always provide the full absolute path. After creating, open the file with open_application or run_shell_command open.
                """
        ),

        MiraSkill(
            id: "diagrams",
            name: "Diagrams",
            tagline: "Generate Mermaid & Excalidraw diagrams",
            icon: "flowchart.fill",
            category: .engineering,
            context: """
                Skill active: Diagrams.
                Generate a diagram HTML file: run_python_skill(skill:"diagram_gen", args:{format:"mermaid", definition:"<mermaid code>", title:"<title>", path?:"~/Desktop/<name>.html", theme?:"dark"}).
                Mermaid diagram types: flowchart TD/LR, sequenceDiagram, classDiagram, erDiagram, gantt, pie, mindmap, gitGraph.
                For Excalidraw: format:"excalidraw", definition:"<excalidraw JSON string>".
                After generating, open the HTML file with run_shell_command("open <path>").
                Always write valid Mermaid syntax — test edge cases (special chars in labels need quotes).
                """
        ),

        MiraSkill(
            id: "claude-code-agent",
            name: "Claude Code Agent",
            tagline: "Delegate coding tasks to Claude Code CLI",
            icon: "terminal.fill",
            category: .engineering,
            context: """
                Skill active: Claude Code Agent.
                Use run_coding_agent(prompt:"<task>", cwd?:"<abs_project_path>", model?:"haiku|sonnet|opus", budget_usd?:0.20) to delegate engineering tasks.
                Choose model: haiku for quick lookups (cheap), sonnet for multi-file edits (default), opus for hard reasoning.
                Always provide cwd when working on a specific project. Cap budget at 0.50 for large tasks.
                The agent has full file read/write/shell access in the cwd. Show its output verbatim — do not re-summarise unless the user asks.
                """
        ),

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

        MiraSkill(
            id: "clone-website",
            name: "Clone Website",
            tagline: "Reverse-engineer any site into clean code",
            icon: "square.on.square.dashed",
            category: .engineering,
            context: """
                Skill active: Clone Website.
                Reverse-engineer a target website into a clean, modern codebase that matches it 1:1.
                Flow: (1) inspect the live site — capture design tokens (colors, typography, spacing, radii, shadows), the layout/grid, and every distinct section; (2) download the real assets (images, video, fonts, favicons) into the project — never placeholders; (3) extract the real copy verbatim; (4) rebuild section-by-section, mobile-first and responsive.
                Fidelity bar: pixel-perfect emulation first — match the target's spacing, color, and type exactly before any personal restyling. Use semantic HTML and sensible component structure; keep real text in markup, not baked into images.
                Verify each section against the original with local renders, screenshots, or build logs — do not ship a section you have not compared to the source.
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
                To extract text from a PDF: run_python_skill(skill:"pdf_extract", args:{path:"<abs_path>", max_chars:40000}).
                For generation use reportlab or fpdf2 via run_shell_command. Provide the absolute output path.
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
                To read: run_python_skill(skill:"docx_rw", args:{op:"read", path:"<abs_path>"}).
                To create: run_python_skill(skill:"docx_rw", args:{op:"write", path:"<abs_path>", content:"<markdown-formatted text>"}).
                To append: run_python_skill(skill:"docx_rw", args:{op:"append", path:"<abs_path>", heading:"<h>", content:"<p>"}).
                Verify paragraph count in the read result after writing. Deliver the absolute file path.
                """
        ),

        MiraSkill(
            id: "youtube-transcript",
            name: "YouTube Transcript",
            tagline: "Fetch & summarise YouTube transcripts",
            icon: "play.rectangle.fill",
            category: .communication,
            context: """
                Skill active: YouTube Transcript.
                To get a transcript: run_python_skill(skill:"youtube_transcript", args:{url:"<youtube_url_or_id>"}).
                Accepts full URLs (https://youtube.com/watch?v=ID or https://youtu.be/ID) or bare 11-char video IDs.
                Returns {success, video_id, text, segments}. If success is false, report the error to the user.
                After fetching, summarise the transcript unless the user asked for the raw text.
                """
        ),

        MiraSkill(
            id: "ocr",
            name: "OCR",
            tagline: "Extract text from images with OCR",
            icon: "text.viewfinder",
            category: .communication,
            context: """
                Skill active: OCR.
                To extract text from an image: run_python_skill(skill:"ocr_image", args:{path:"<abs_path>", lang:"eng"}).
                Supports PNG, JPG, TIFF, BMP. lang accepts tesseract codes like "eng", "fra", "eng+fra".
                Returns {success, text, confidence}. If success is false the error will explain if tesseract is missing (brew install tesseract).
                Report the confidence value to the user if it is below 70.
                """
        ),

        MiraSkill(
            id: "reminders",
            name: "Reminders",
            tagline: "Read & write Apple Reminders lists",
            icon: "checklist",
            category: .productivity,
            context: """
                Skill active: Reminders.
                To list all reminder lists: run_python_skill(skill:"reminders_rw", args:{op:"list_lists"}).
                To list reminders (all or by list): run_python_skill(skill:"reminders_rw", args:{op:"list", list?:"<name>", include_completed?:false}).
                To add a reminder: run_python_skill(skill:"reminders_rw", args:{op:"add", title:"<text>", list?:"Reminders", due?:"YYYY-MM-DD HH:MM", notes?:"<text>"}).
                To complete: run_python_skill(skill:"reminders_rw", args:{op:"complete", query:"<title fragment>", list?:"<name>"}).
                To delete: run_python_skill(skill:"reminders_rw", args:{op:"delete", query:"<title fragment>"}).
                To search: run_python_skill(skill:"reminders_rw", args:{op:"search", query:"<text>"}).
                Confirm before deleting. Show due dates prominently. Group by list when listing all.
                """
        ),

        MiraSkill(
            id: "notes",
            name: "Apple Notes",
            tagline: "Read, create & edit Apple Notes",
            icon: "note.text",
            category: .productivity,
            context: """
                Skill active: Apple Notes.
                To list folders: run_python_skill(skill:"notes_rw", args:{op:"list_folders"}).
                To list recent notes: run_python_skill(skill:"notes_rw", args:{op:"list", folder?:"<name>", count?:20}).
                To read a note: run_python_skill(skill:"notes_rw", args:{op:"read", title:"<partial title>"}).
                To create: run_python_skill(skill:"notes_rw", args:{op:"create", title:"<title>", body:"<text>", folder?:"Notes"}).
                To append: run_python_skill(skill:"notes_rw", args:{op:"append", title:"<partial title>", text:"<content to add>"}).
                To search: run_python_skill(skill:"notes_rw", args:{op:"search", query:"<text>", count?:10}).
                Requires Automation permission for Notes.app.
                """
        ),

        MiraSkill(
            id: "maps",
            name: "Maps",
            tagline: "Directions, nearby places & geocoding",
            icon: "map.fill",
            category: .productivity,
            context: """
                Skill active: Maps.
                All map ops use OpenStreetMap — no API key needed.
                Geocode a place: run_python_skill(skill:"maps", args:{op:"geocode", query:"<place name>"}).
                Reverse geocode: run_python_skill(skill:"maps", args:{op:"reverse", lat:<n>, lon:<n>}).
                Find nearby POIs: run_python_skill(skill:"maps", args:{op:"nearby", near:"<place>", category:"<restaurant|cafe|pharmacy|hospital|bank|parking|hotel|gym|park|...>", radius_m?:800, limit?:10}).
                Directions: run_python_skill(skill:"maps", args:{op:"route", origin:"<place>", destination:"<place>", mode?:"driving|walking|cycling"}).
                Distance: run_python_skill(skill:"maps", args:{op:"distance", from:"<place>", to:"<place>"}).
                Present distances in km with driving time in minutes. For nearby results, sort by dist_m and show top 5 with name, distance, and opening hours.
                """
        ),

        MiraSkill(
            id: "computer-use",
            name: "Computer Use",
            tagline: "Drive any Mac app or browser on your desktop",
            icon: "cursorarrow.click.2",
            category: .engineering,
            context: """
                Skill active: Computer Use.
                Use mcp__computer-use__* tools to automate the macOS desktop.
                Flow: request_access → screenshot → act → screenshot (verify).
                Browser tier is read-only — use open_application for URL nav. Terminal tier is click-only.
                No-foreground contract: user's active app MUST NOT change.
                For background browser work: use open_application with bundle_id + urls:[...].
                Stop before: form submit, send, payment, delete, account change. Always confirm.
                """
        ),

        MiraSkill(
            id: "obsidian",
            name: "Obsidian",
            tagline: "Read, create & search your Obsidian vault",
            icon: "diamond.fill",
            category: .productivity,
            context: """
                Skill active: Obsidian.
                To list vault notes: run_python_skill(skill:"obsidian_rw", args:{op:"list_vault", vault_path?:"<abs_path>", limit?:50}).
                To read a note: run_python_skill(skill:"obsidian_rw", args:{op:"read", title:"<partial title>", vault_path?:"<abs_path>", max_chars?:8000}).
                To create a note: run_python_skill(skill:"obsidian_rw", args:{op:"create", title:"<title>", body:"<markdown>", folder?:"<subfolder>", tags?:["tag1"], vault_path?:"<abs_path>"}).
                To append: run_python_skill(skill:"obsidian_rw", args:{op:"append", title:"<partial title>", text:"<markdown>", vault_path?:"<abs_path>"}).
                To search: run_python_skill(skill:"obsidian_rw", args:{op:"search", query:"<text>", vault_path?:"<abs_path>", limit?:10}).
                To list wikilinks: run_python_skill(skill:"obsidian_rw", args:{op:"wikilinks", title:"<partial title>", vault_path?:"<abs_path>"}).
                The skill auto-detects the vault from common locations. Pass vault_path to override.
                """
        ),

        MiraSkill(
            id: "polymarket",
            name: "Polymarket",
            tagline: "Live prediction market odds & probabilities",
            icon: "chart.line.uptrend.xyaxis",
            category: .productivity,
            context: """
                Skill active: Polymarket.
                To get trending markets: run_python_skill(skill:"polymarket", args:{op:"trending", limit?:10}).
                To search markets: run_python_skill(skill:"polymarket", args:{op:"search", query:"<topic>", limit?:5}).
                To get market detail by slug: run_python_skill(skill:"polymarket", args:{op:"detail", slug:"<market-slug>"}).
                Returns outcome probabilities as percentages (e.g. "Yes: 73.2%"). Present as a table when listing multiple markets. Always note that these are prediction market odds, not guaranteed outcomes.
                """
        ),

        MiraSkill(
            id: "findmy",
            name: "Find My",
            tagline: "List your Apple devices from FindMy",
            icon: "location.fill",
            category: .productivity,
            context: """
                Skill active: Find My.
                To list registered Apple devices: run_python_skill(skill:"findmy_devices", args:{}).
                Returns {success, devices:[{name, owner_first, owner_last}], total, note}.
                Present as a clean list: device name + owner full name.
                Real-time location data is protected by Apple and cannot be read directly. \
                If the user asks for a device's location: \
                (1) list devices first, (2) offer to open FindMy.app with open_application(app_name:"FindMy"), \
                or (3) take a screenshot via get_current_context after the user opens it.
                """
        ),

        MiraSkill(
            id: "blender",
            name: "Blender",
            tagline: "Automate 3D scenes via WebSocket control",
            icon: "cube.fill",
            category: .engineering,
            context: """
                Skill active: Blender.
                Control Blender via the Blender Toolkit WebSocket addon (default port 9400).
                Prereqs: Blender 4.0+ installed, addon enabled, server started (View3D → Sidebar N → "Blender Toolkit" → Start Server).
                CLI: blender-toolkit <command>. Common operations:
                  Geometry: create-cube/sphere/cylinder --size, list-objects, transform --name, duplicate
                  Materials: material create/assign/set-color/set-metallic/set-roughness
                  Modifiers: modifier add/apply --object --type (SUBDIVISION, MIRROR, ARRAY, etc.)
                  Animation: retarget --target <armature> --file <FBX> [--mapping mixamo_to_rigify] [--skip-confirmation]
                Retargeting uses two-phase workflow: auto bone-map → user reviews in Blender UI → Apply Retargeting.
                Quality: Excellent (8-9 bones) → skip-confirmation OK; Good/Fair → require review; Poor → custom mapping.
                Mixamo has no API — guide user to download FBX manually, then call retarget.
                Never guess armature names — list-objects --type ARMATURE first.
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

        // MARK: Spotify (ported from farzaa/clicky spotify.md, MIT)

        MiraSkill(
            id: "spotify",
            name: "Spotify",
            tagline: "Play, search, queue & manage playlists",
            icon: "music.note",
            category: .productivity,
            context: """
                Skill active: Spotify.
                Use control_spotify(action:...) for all playback control.
                Actions: "play", "pause", "toggle", "next", "previous", "play_song", "quit".
                When user says "play X" or "play X on Spotify": call control_spotify(action:"play_song", ...). \
                If the user names both a song and an artist, pass them as track: and artist: \
                (order in their phrasing doesn't matter); otherwise pass the whole phrase as song:. \
                It starts playback immediately — no need to call play afterward.
                Prefer the structured control_spotify tool over AppleScript for Spotify. \
                Playback-mutating actions require Spotify Premium.
                """
        ),

        // MARK: iMessage (ported from farzaa/clicky imessage.md, MIT)

        MiraSkill(
            id: "imessage",
            name: "iMessage",
            tagline: "Send & read iMessages via AppleScript",
            icon: "message.fill",
            category: .communication,
            context: """
                Skill active: iMessage.
                Use run_apple_script to send and read iMessages via Messages.app.
                To send: run_apple_script("tell application \\"Messages\\" to send \\"<text>\\" to buddy \\"<number or Apple ID>\\" of service \\"iMessage\\"").
                To read recent chats: run_shell_command("imsg chats --limit 10 --json") — requires `brew install steipete/tap/imsg`.
                ALWAYS confirm recipient and message text before sending. Never send without explicit user approval. \
                For group chats or attachments, use run_apple_script with the relevant Messages.app AppleScript dictionary.
                Requires Automation permission for Messages.app.
                """
        ),
    ]
}
