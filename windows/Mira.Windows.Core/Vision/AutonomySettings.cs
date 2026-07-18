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
        get => LoadEnabled();
        set => Persist(value);
    }

    private static bool LoadEnabled()
    {
        var path = LocalAppData.PathFor(FileName);
        if (!File.Exists(path)) return false;
        try
        {
            var raw = Newtonsoft.Json.Linq.JObject.Parse(File.ReadAllText(path));
            return (bool?)raw["computer_use_enabled"] ?? false;
        }
        catch
        {
            return false;
        }
    }

    private static void Persist(bool enabled)
    {
        var json = new Newtonsoft.Json.Linq.JObject { ["computer_use_enabled"] = enabled }
            .ToString(Newtonsoft.Json.Formatting.None);
        File.WriteAllText(LocalAppData.PathFor(FileName), json);
    }
}
