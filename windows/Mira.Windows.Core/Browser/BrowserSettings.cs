using Mira.Windows.Core.Storage;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Browser;

/// <summary>
/// The Windows equivalent of macOS's <c>BrowserService.preferredKey</c>
/// (SettingsView.swift's "Web Browser" row) — which installed browser opens
/// search results, video links, place lookups, etc. Null means "system
/// default" (plain <c>Process.Start(url) {"UseShellExecute": true}</c>,
/// what every route already did before this setting existed).
/// </summary>
public static class BrowserSettings
{
    private const string FileName = "browser.json";

    public static string? PreferredBrowserPath
    {
        get
        {
            var path = LocalAppData.PathFor(FileName);
            if (!File.Exists(path)) return null;
            try { return (string?)JObject.Parse(File.ReadAllText(path))["preferred_browser_path"]; }
            catch { return null; }
        }
        set
        {
            var json = new JObject { ["preferred_browser_path"] = value }.ToString(Newtonsoft.Json.Formatting.None);
            File.WriteAllText(LocalAppData.PathFor(FileName), json);
        }
    }
}
