using Mira.Windows.Core.Storage;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Voice;

/// <summary>
/// Persisted input/output device preference for Mira's own voice capture
/// (<see cref="RealtimeMicCapture"/>) and playback (<see cref="RealtimePlaybackSink"/>).
/// Mac has no equivalent (AVFoundation's mic/output picker is a system-level
/// choice there); this exists because Windows machines commonly have several
/// active capture/render devices (a webcam mic alongside a headset, HDMI
/// audio alongside speakers) and WASAPI's implicit "default device" isn't
/// always the one the user actually wants Mira listening to or speaking
/// through. Null means "use whatever Windows currently has set as default."
/// </summary>
public static class AudioDeviceSettings
{
    private const string FileName = "audio_devices.json";

    public static string? PreferredInputDeviceId
    {
        get => LoadString("input_device_id");
        set => Persist("input_device_id", value);
    }

    public static string? PreferredOutputDeviceId
    {
        get => LoadString("output_device_id");
        set => Persist("output_device_id", value);
    }

    private static string? LoadString(string key)
    {
        var path = LocalAppData.PathFor(FileName);
        if (!File.Exists(path)) return null;
        try { return (string?)JObject.Parse(File.ReadAllText(path))[key]; }
        catch { return null; }
    }

    private static void Persist(string key, string? value)
    {
        var path = LocalAppData.PathFor(FileName);
        JObject json;
        try { json = File.Exists(path) ? JObject.Parse(File.ReadAllText(path)) : new JObject(); }
        catch { json = new JObject(); }

        json[key] = value;
        File.WriteAllText(path, json.ToString(Newtonsoft.Json.Formatting.None));
    }
}
