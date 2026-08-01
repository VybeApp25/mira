using Mira.Windows.Core.Storage;

namespace Mira.Windows.Core.Vision;

/// <summary>
/// The Windows equivalent of the macOS client's <c>mira_autonomous_enabled</c>
/// UserDefaults flag (checked in RouterService.swift's <c>.computerUse</c>
/// case) — computer-use is a deliberate opt-in: a chat request can only drive
/// the screen if the user has explicitly turned this on. Off by default,
/// exactly like the Mac client.
/// </summary>
public static class AutonomySettings
{
    private const string FileName = "autonomy.json";

    public static bool ComputerUseEnabled
    {
        get => LoadBool("computer_use_enabled", false);
        set => Persist("computer_use_enabled", value);
    }

    /// <summary>
    /// The Windows equivalent of macOS's <c>mira_autonomous_confirm_risky</c>
    /// (SettingsView.swift's Autonomous section) — default true, matching Mac:
    /// "Pause before anything irreversible (send, delete, buy, submit…). Off =
    /// fully hands-off." Checked by <see cref="Chat.RouterHandler"/>'s
    /// <c>computer_use</c> handler as a pre-flight keyword gate rather than a
    /// mid-task pause — this port's <see cref="ComputerUseOrchestrator"/> runs
    /// as a single synchronous loop with no pause/resume point built in yet,
    /// so gating before the loop starts (reusing the existing
    /// <c>RouteResultKind.Confirm</c> flow already used elsewhere) is the
    /// honest, bounded equivalent rather than a deeper per-step pause this
    /// pass doesn't build.
    /// </summary>
    public static bool ConfirmRiskyActions
    {
        get => LoadBool("confirm_risky_actions", true);
        set => Persist("confirm_risky_actions", value);
    }

    private static bool LoadBool(string key, bool fallback)
    {
        var path = LocalAppData.PathFor(FileName);
        if (!File.Exists(path)) return fallback;
        try
        {
            var raw = Newtonsoft.Json.Linq.JObject.Parse(File.ReadAllText(path));
            return (bool?)raw[key] ?? fallback;
        }
        catch
        {
            return fallback;
        }
    }

    private static void Persist(string key, bool value)
    {
        var path = LocalAppData.PathFor(FileName);
        Newtonsoft.Json.Linq.JObject json;
        try { json = File.Exists(path) ? Newtonsoft.Json.Linq.JObject.Parse(File.ReadAllText(path)) : new Newtonsoft.Json.Linq.JObject(); }
        catch { json = new Newtonsoft.Json.Linq.JObject(); }

        json[key] = value;
        File.WriteAllText(path, json.ToString(Newtonsoft.Json.Formatting.None));
    }
}
