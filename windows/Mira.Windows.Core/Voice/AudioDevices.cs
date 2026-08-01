using NAudio.CoreAudioApi;

namespace Mira.Windows.Core.Voice;

public sealed record AudioDeviceInfo(string Id, string Name);

/// <summary>
/// WASAPI device enumeration backing the Settings input/output pickers.
/// Lives in Core (not behind a WinRT bridge like <see cref="Chat.NowPlayingBridge"/>)
/// because NAudio's <see cref="MMDeviceEnumerator"/> is a plain managed API
/// Core already depends on for <see cref="RealtimeMicCapture"/>/<see cref="RealtimePlaybackSink"/>.
/// </summary>
public static class AudioDevices
{
    public static List<AudioDeviceInfo> ListInputDevices() => ListDevices(DataFlow.Capture);

    public static List<AudioDeviceInfo> ListOutputDevices() => ListDevices(DataFlow.Render);

    private static List<AudioDeviceInfo> ListDevices(DataFlow flow)
    {
        var result = new List<AudioDeviceInfo>();
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var devices = enumerator.EnumerateAudioEndPoints(flow, DeviceState.Active);
            foreach (var device in devices)
            {
                result.Add(new AudioDeviceInfo(device.ID, device.FriendlyName));
                device.Dispose();
            }
        }
        catch
        {
            // No audio subsystem available (or COM not initialized on this thread) -- callers
            // treat an empty list the same as "nothing to offer beyond system default."
        }
        return result;
    }

    /// <summary>
    /// The device Windows' own on-device speech recognition (<see cref="Chat.WakeWordBridge"/>'s
    /// real WinRT-backed implementation) actually listens through -- unlike
    /// <see cref="RealtimeMicCapture"/>, that API has no public device-selection
    /// hook, so this is surfaced read-only next to the wake word toggle so the
    /// user knows which physical microphone to check/change in Windows Sound
    /// settings if "Hey Mira" isn't hearing them.
    /// </summary>
    public static string? DefaultWakeWordInputDeviceName()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
            return device.FriendlyName;
        }
        catch
        {
            return null;
        }
    }
}
