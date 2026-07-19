using Mira.Windows.Core.Storage;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Voice;

/// <summary>
/// The Windows equivalent of macOS's <c>isAlwaysOn</c> concept
/// (<c>RealtimeVoiceService.swift</c>'s <c>connectAlwaysOn()</c>/<c>disconnectAlwaysOn()</c>) --
/// when enabled, a voice session stays open persistently (started at app
/// launch and by this checkbox) rather than only ever being started by wake
/// word or the mic button. Off by default, matching Mac.
/// </summary>
public static class VoiceAlwaysOnSettings
{
    private const string FileName = "voice_always_on.json";

    public static bool IsEnabled
    {
        get
        {
            var path = LocalAppData.PathFor(FileName);
            if (!File.Exists(path)) return false;
            try { return (bool?)JObject.Parse(File.ReadAllText(path))["always_on_enabled"] ?? false; }
            catch { return false; }
        }
        set
        {
            var json = new JObject { ["always_on_enabled"] = value }.ToString(Newtonsoft.Json.Formatting.None);
            File.WriteAllText(LocalAppData.PathFor(FileName), json);
        }
    }
}
