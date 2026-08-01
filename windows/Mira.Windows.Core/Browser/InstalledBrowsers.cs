using Microsoft.Win32;

namespace Mira.Windows.Core.Browser;

public sealed record InstalledBrowser(string Name, string ExePath);

/// <summary>
/// Enumerates installed browsers via the same registry convention Windows'
/// own "Default apps" picker reads: each browser registers a subkey under
/// <c>...\Clients\StartMenuInternet</c> (per-machine and/or per-user) whose
/// default value is the display name and whose
/// <c>shell\open\command</c> default value is the launch command line.
/// </summary>
public static class InstalledBrowsers
{
    private const string StartMenuInternetPath = @"SOFTWARE\Clients\StartMenuInternet";

    public static IReadOnlyList<InstalledBrowser> Detect()
    {
        var results = new Dictionary<string, InstalledBrowser>(StringComparer.OrdinalIgnoreCase);

        foreach (var root in new[] { Registry.LocalMachine, Registry.CurrentUser })
        {
            using var clientsKey = root.OpenSubKey(StartMenuInternetPath);
            if (clientsKey is null) continue;

            foreach (var subKeyName in clientsKey.GetSubKeyNames())
            {
                using var browserKey = clientsKey.OpenSubKey(subKeyName);
                using var commandKey = browserKey?.OpenSubKey(@"shell\open\command");
                var commandLine = (string?)commandKey?.GetValue(null);
                if (string.IsNullOrWhiteSpace(commandLine)) continue;

                var exePath = ExtractExePath(commandLine);
                if (exePath is null || !File.Exists(exePath)) continue;

                var name = (string?)browserKey?.GetValue(null) ?? subKeyName;
                results[name] = new InstalledBrowser(name, exePath);
            }
        }

        return results.Values.OrderBy(b => b.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    /// <summary>Pure — strips a registry command line down to just the executable path, mirroring how Windows itself resolves these entries: a quoted path, or the first whitespace-delimited token.</summary>
    public static string? ExtractExePath(string commandLine)
    {
        var trimmed = commandLine.Trim();
        if (trimmed.Length == 0) return null;

        if (trimmed[0] == '"')
        {
            var closingQuote = trimmed.IndexOf('"', 1);
            return closingQuote > 0 ? trimmed[1..closingQuote] : null;
        }

        var spaceIndex = trimmed.IndexOf(' ');
        return spaceIndex > 0 ? trimmed[..spaceIndex] : trimmed;
    }
}
