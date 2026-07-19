using Mira.Windows.Core.Storage;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Chat;

/// <summary>
/// The Windows equivalent of macOS's <c>mira_show_in_capture</c> UserDefaults
/// flag (SettingsView.swift's Appearance section: "Show in screen recordings").
/// This is only the persisted preference — the actual Win32
/// <c>SetWindowDisplayAffinity</c> call lives in
/// <c>Mira.Windows.App/Shell/CaptureAffinity.cs</c> (Core has no HWND to act
/// on), applied fresh at every launch since the OS doesn't remember display
/// affinity across window creations.
/// </summary>
public static class AppearanceSettings
{
    private const string FileName = "appearance.json";

    public static bool ShowInScreenCaptures
    {
        get
        {
            var path = LocalAppData.PathFor(FileName);
            if (!File.Exists(path)) return true;
            try { return (bool?)JObject.Parse(File.ReadAllText(path))["show_in_screen_captures"] ?? true; }
            catch { return true; }
        }
        set
        {
            var json = new JObject { ["show_in_screen_captures"] = value }.ToString(Newtonsoft.Json.Formatting.None);
            File.WriteAllText(LocalAppData.PathFor(FileName), json);
        }
    }
}
