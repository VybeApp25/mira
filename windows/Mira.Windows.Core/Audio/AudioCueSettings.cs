using Mira.Windows.Core.Storage;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Audio;

/// <summary>
/// The Windows equivalent of AudioCueService.swift's <c>isMuted</c>/
/// <c>isCueEnabled</c>/<c>setCueEnabled</c> UserDefaults-backed settings.
/// Per-cue enable/disable exists (matching Mac's own API) but, like Mac, has
/// no dedicated Settings UI of its own -- only the master mute is surfaced.
/// </summary>
public static class AudioCueSettings
{
    private const string FileName = "audio_cues.json";

    public static bool IsMuted
    {
        get
        {
            var path = LocalAppData.PathFor(FileName);
            if (!File.Exists(path)) return false;
            try { return (bool?)JObject.Parse(File.ReadAllText(path))["muted"] ?? false; }
            catch { return false; }
        }
        set => Persist("muted", value);
    }

    public static bool IsCueEnabled(string name)
    {
        var path = LocalAppData.PathFor(FileName);
        if (!File.Exists(path)) return true;
        try { return (bool?)JObject.Parse(File.ReadAllText(path))[$"cue_{name}"] ?? true; }
        catch { return true; }
    }

    public static void SetCueEnabled(string name, bool enabled) => Persist($"cue_{name}", enabled);

    private static void Persist(string key, bool value)
    {
        var path = LocalAppData.PathFor(FileName);
        JObject json;
        try { json = File.Exists(path) ? JObject.Parse(File.ReadAllText(path)) : new JObject(); }
        catch { json = new JObject(); }

        json[key] = value;
        File.WriteAllText(path, json.ToString(Newtonsoft.Json.Formatting.None));
    }
}
