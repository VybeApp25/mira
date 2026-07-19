using Mira.Windows.Core.Storage;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Voice;

/// <summary>
/// The Windows equivalent of macOS's hidden <c>mira_voice_screen_context</c>
/// UserDefaults flag (RealtimeVoiceService.swift's <c>screenContextEnabled</c>) —
/// like Mac, this has no visible Settings UI toggle (Mac's own comment:
/// "Disable with <c>defaults write … mira_voice_screen_context -bool NO</c>"),
/// just a persisted preference defaulting to on.
/// </summary>
public static class VoiceScreenContextSettings
{
    private const string FileName = "voice_screen_context.json";

    public static bool IsEnabled
    {
        get
        {
            var path = LocalAppData.PathFor(FileName);
            if (!File.Exists(path)) return true;
            try { return (bool?)JObject.Parse(File.ReadAllText(path))["screen_context_enabled"] ?? true; }
            catch { return true; }
        }
        set
        {
            var json = new JObject { ["screen_context_enabled"] = value }.ToString(Newtonsoft.Json.Formatting.None);
            File.WriteAllText(LocalAppData.PathFor(FileName), json);
        }
    }
}
