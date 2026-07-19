using System.Diagnostics;

namespace Mira.Windows.Core.Browser;

/// <summary>
/// Every route that opens a URL (web search, video playback, open-url, image
/// search, maps) goes through here instead of calling <see cref="Process.Start(ProcessStartInfo)"/>
/// directly, so <see cref="BrowserSettings.PreferredBrowserPath"/> is actually
/// respected end to end rather than being a setting nothing reads.
/// </summary>
public static class BrowserLauncher
{
    public static void Open(string url)
    {
        var preferred = BrowserSettings.PreferredBrowserPath;
        if (!string.IsNullOrEmpty(preferred) && File.Exists(preferred))
        {
            Process.Start(new ProcessStartInfo(preferred, $"\"{url}\""));
            return;
        }

        Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
    }
}
