using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Mira.Windows.Core.Voice;

/// <summary>
/// The Windows equivalent of the playback half of
/// Mira/Services/RealtimeVoiceService.swift's <c>AVAudioEngine</c>/<c>AVAudioPlayerNode</c>
/// setup — buffers and plays the 24kHz mono 16-bit PCM chunks the Realtime API
/// streams back (<c>response.output_audio.delta</c> events, base64-decoded by the caller).
///
/// Uses <see cref="WaveOutEvent"/> (the classic Windows waveOut API) for the
/// system-default case rather than <c>WasapiOut</c>: WASAPI shared-mode
/// playback expects the provider's format to match the output device's own
/// mix format (commonly 48kHz stereo float), which would mean querying the
/// device and re-wrapping in a second resampler purely for playback —
/// <c>WaveOutEvent</c> handles arbitrary PCM formats directly and is the
/// standard NAudio choice for exactly this "I have PCM, just play it" case.
/// When the user picks a *specific* non-default device, though, WaveOutEvent's
/// legacy WinMM device-ordinal API has no reliable way to target it by ID, so
/// that case does use <c>WasapiOut</c> with the pure-managed
/// <see cref="WdlResamplingSampleProvider"/> (not <c>MediaFoundationResampler</c>
/// — confirmed elsewhere in this port that it crashes across capture-callback
/// thread boundaries; the same caution applies here) to match the device's mix format.
/// </summary>
public sealed class RealtimePlaybackSink : IDisposable
{
    private readonly IWavePlayer _output;
    private readonly BufferedWaveProvider _buffer;
    private bool _disposed;

    /// <param name="deviceId">
    /// An <see cref="MMDevice.ID"/> from <see cref="AudioDevices.ListOutputDevices"/>
    /// (persisted as <see cref="AudioDeviceSettings.PreferredOutputDeviceId"/>), or
    /// null/invalid/unsupported (e.g. a >2-channel device) to fall back to the
    /// system default output device.
    /// </param>
    public RealtimePlaybackSink(string? deviceId = null)
    {
        _buffer = new BufferedWaveProvider(RealtimeAudioFormat.WaveFormat)
        {
            DiscardOnBufferOverflow = false,
            BufferDuration = TimeSpan.FromSeconds(30),
        };
        _output = ResolveOutput(deviceId, _buffer);
        _output.Play();
    }

    private static IWavePlayer ResolveOutput(string? deviceId, BufferedWaveProvider buffer)
    {
        if (!string.IsNullOrEmpty(deviceId))
        {
            try
            {
                using var enumerator = new MMDeviceEnumerator();
                var device = enumerator.GetDevice(deviceId);
                var mixFormat = device.AudioClient.MixFormat;

                // Only mono and stereo device mix formats are handled -- surround
                // devices are rare for this app's use case and fall back to the
                // system default rather than guess at a channel-duplication scheme.
                if (mixFormat.Channels is 1 or 2)
                {
                    ISampleProvider samples = buffer.ToSampleProvider();
                    if (mixFormat.SampleRate != RealtimeAudioFormat.SampleRate)
                        samples = new WdlResamplingSampleProvider(samples, mixFormat.SampleRate);
                    if (mixFormat.Channels == 2)
                        samples = new MonoToStereoSampleProvider(samples);

                    var wasapiOut = new WasapiOut(device, AudioClientShareMode.Shared, true, 100);
                    wasapiOut.Init(samples);
                    return wasapiOut;
                }
            }
            catch
            {
                // Device unplugged/renamed/unsupported since the preference was
                // saved -- fall through to the system default below.
            }
        }

        var waveOut = new WaveOutEvent();
        waveOut.Init(buffer);
        return waveOut;
    }

    /// <summary>Enqueues a chunk of 24kHz mono 16-bit PCM for playback.</summary>
    public void Enqueue(byte[] pcm16, int count) => _buffer.AddSamples(pcm16, 0, count);

    /// <summary>
    /// True once every enqueued sample has actually played (buffer drained). The
    /// Swift original schedules an explicit silent "sentinel" buffer and fires a
    /// completion callback exactly when it plays — a more precise mechanism than
    /// this port's polling approach, which is a deliberate simplification.
    /// </summary>
    public bool IsDrained => _buffer.BufferedBytes == 0;

    /// <summary>Discards any buffered-but-unplayed audio — used when a new turn interrupts a still-speaking reply.</summary>
    public void ClearPending() => _buffer.ClearBuffer();

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _output.Stop();
        _output.Dispose();
    }
}
