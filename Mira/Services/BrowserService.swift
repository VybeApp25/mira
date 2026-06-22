import Foundation
import AppKit

/// Detects the web browsers installed on this Mac and opens URLs in the user's
/// chosen browser. Opening a URL is free (no screenshots) — this is the visible
/// path Mira uses to *show* search results / web pages to the user, while the
/// spoken answer comes from a cheap text path (see RouterService.webSearch).
@MainActor
final class BrowserService {
    static let shared = BrowserService()
    private init() {}

    /// UserDefaults key holding the preferred browser's bundle identifier.
    /// Empty / missing → use the system default browser.
    static let preferredKey = "mira_preferred_browser_bundle"

    struct Browser: Identifiable, Hashable {
        let bundleID: String
        let name:     String
        let url:      URL
        var id: String { bundleID }
    }

    private static let probeURL = URL(string: "https://example.com")!

    private static func name(for appURL: URL, bundle: Bundle?) -> String {
        (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
            ?? FileManager.default.displayName(atPath: appURL.path)
                .replacingOccurrences(of: ".app", with: "")
    }

    /// Every app registered to handle https:// — i.e. the browsers installed on
    /// this Mac (Safari, Chrome, Arc, Firefox, Edge, ChatGPT Atlas, …).
    func installedBrowsers() -> [Browser] {
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: Self.probeURL)
        var seen: Set<String> = []
        var result: [Browser] = []
        for appURL in urls {
            let bundle = Bundle(url: appURL)
            guard let bid = bundle?.bundleIdentifier, !seen.contains(bid) else { continue }
            seen.insert(bid)
            result.append(Browser(bundleID: bid, name: Self.name(for: appURL, bundle: bundle), url: appURL))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The system default browser, if resolvable.
    func defaultBrowser() -> Browser? {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: Self.probeURL) else { return nil }
        let bundle = Bundle(url: appURL)
        guard let bid = bundle?.bundleIdentifier else { return nil }
        return Browser(bundleID: bid, name: Self.name(for: appURL, bundle: bundle), url: appURL)
    }

    /// The browser Mira should use: the preferred one if set & still installed,
    /// otherwise the system default.
    func activeBrowser() -> Browser? {
        let pref = UserDefaults.standard.string(forKey: Self.preferredKey) ?? ""
        if !pref.isEmpty,
           let match = installedBrowsers().first(where: { $0.bundleID == pref }) {
            return match
        }
        return defaultBrowser()
    }

    /// Opens a URL visibly in the active browser, bringing it to the front.
    /// Returns the browser's display name (for the spoken/printed confirmation).
    @discardableResult
    func open(_ url: URL) -> String {
        if let browser = activeBrowser() {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: browser.url, configuration: cfg)
            return browser.name
        }
        NSWorkspace.shared.open(url)
        return "your browser"
    }

    /// A Google search-results URL for a natural-language query.
    static func searchURL(for query: String) -> URL? {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://www.google.com/search?q=\(q)")
    }
}
