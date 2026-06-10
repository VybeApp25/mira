import AppKit

// Watches the frontmost app and exposes a short context snippet
// for Claude's system prompt (2-4 sentences per app).
// Covers the same apps as HeyClicky's bundled .md library.
@MainActor
final class AppContextService {
    static let shared = AppContextService()
    private init() { observe() }

    private(set) var frontmostBundleID: String? = nil
    private(set) var currentContext: String?     = nil

    // Thread-safe cache for nonisolated access from MiraPrompts.system.
    nonisolated(unsafe) static var cachedContext: String? = nil

    // MARK: - Bundle ID → context map

    // Keyed on the prefix so variations (e.g. "com.notion.id" vs "notion.id") match.
    private static let contextMap: [(prefix: String, context: String)] = [

        ("com.notion", """
            The user has Notion open. Prefer Composio Notion tools when available; otherwise use the Notion REST API via curl with Authorization: Bearer $NOTION_API_KEY and Notion-Version header. Key ops: search pages, create pages in a database, query a database with /data_sources/{id}/query, append blocks. Always share the integration with target pages first.
            """),

        ("com.linear", """
            The user has Linear open. Use the Linear GraphQL API (api.linear.app/graphql) with Authorization: Bearer $LINEAR_API_KEY. For issues: create with IssueCreate mutation, query with issues(filter:{}) query. Prefer the Composio Linear toolkit when attached.
            """),

        ("com.spotify", """
            The user has Spotify open. Use Composio Spotify tools (spotify_playback, spotify_search, spotify_playlists, spotify_queue). For "play X": search then play by URI — don't loop describing results. Playback mutations require Premium. A 403 with "No active device" means Spotify isn't playing anywhere — ask the user to start it first.
            """),

        ("com.apple.Notes", """
            The user has Apple Notes open. Use AppleScript via System Events to create/read notes: 'tell application "Notes" to make new note with properties {name:"...", body:"..."}'. For search: 'tell application "Notes" to search "query"'. Notes are in iCloud by default.
            """),

        ("com.apple.reminders", """
            The user has Reminders open. Use AppleScript: 'tell application "Reminders" to make new reminder with properties {name:"...", due date:date "..."}'. List with 'every reminder'. Preferred over shell reminders commands.
            """),

        ("com.apple.MobileSMS", """
            The user has Messages open. Use AppleScript to send iMessages: 'tell application "Messages" to send "text" to buddy "phone-or-email" of service "iMessage"'. Read-only thread access is not scriptable — use Computer Use if the user wants to read conversations.
            """),

        ("com.github", """
            The user has GitHub open. Use the gh CLI for repo operations: gh issue create/list, gh pr create/list/view, gh repo clone. For REST: curl -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/... . Always check auth with gh auth status first.
            """),

        ("com.google.Chrome", """
            The user has Chrome open. For web tasks, prefer structured APIs (Composio, curl, gh) over Computer Use. If Computer Use is needed for Chrome: use get_window_state to snapshot the AX tree, then act by element_index. The first snapshot for Chrome may take ~500 ms while the accessibility tree populates — retry once if sparse.
            """),

        ("com.apple.Safari", """
            The user has Safari open. For web tasks prefer structured APIs first. If Computer Use is needed: Safari's AX tree is more complete than Chrome's by default. Use get_window_state then act by element_index.
            """),

        ("com.figma", """
            The user has Figma open. Figma has a REST API (api.figma.com/v1) for reading files and components. For actual design mutations, Computer Use is the best path — Figma's desktop app has good AX support. Use get_window_state to inspect the current canvas.
            """),

        ("com.microsoft.VSCode", """
            The user has VS Code open. Prefer shell/terminal tools for code tasks (file read/write, git, npm). VS Code has a CLI: `code --goto file:line`. For editor UI operations, the AX tree is available via Computer Use.
            """),

        ("md.obsidian", """
            The user has Obsidian open. The vault is a folder of Markdown files. Use shell tools to read/write .md files directly in the vault path. For links: [[Note Title]] syntax. Front matter uses YAML between --- delimiters. Find the vault path in ~/Library/Application Support/obsidian/obsidian.json.
            """),

        ("com.airtable", """
            The user has Airtable open. Use the Airtable REST API (api.airtable.com/v0/{baseId}/{tableId}) with Authorization: Bearer $AIRTABLE_API_KEY. List records: GET with ?filterByFormula=. Create: POST with {fields:{...}}. Update: PATCH with [{id,fields}]. Use Composio Airtable tools when attached.
            """),

        ("com.vercel", """
            The user has Vercel open. Use the Vercel CLI (vercel / npx vercel) for deploys. Production: vercel --prod. List deployments: vercel list. Logs: vercel logs <url>. The Vercel REST API uses Authorization: Bearer $VERCEL_TOKEN.
            """),
    ]

    // MARK: - Observation

    private func observe() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        updateContext(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    @objc private func appDidActivate(_ note: Notification) {
        let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
        updateContext(bundleID)
    }

    private func updateContext(_ bundleID: String?) {
        frontmostBundleID = bundleID
        guard let id = bundleID else {
            currentContext = nil
            Self.cachedContext = nil
            return
        }
        let ctx = Self.contextMap.first { id.hasPrefix($0.prefix) }?.context
        currentContext    = ctx
        Self.cachedContext = ctx
    }
}
