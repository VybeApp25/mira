using NAudio.Wave;

namespace Mira.Windows.Core.Voice;

/// <summary>
/// The Windows equivalent of the playback half of
/// Mira/Services/RealtimeVoiceService.swift's <c>AVAudioEngine</c>/<c>AVAudioPlayerNode</c>
/// setup — buffers and plays the 24kHz mono 16-bit PCM chunks the Realtime API
/// streams back (<c>response.output_audio.delta</c> events, base64-decoded by the caller).
///
/// Uses <see cref="WaveOutEvent"/> (the classic Windows waveOut API) rather than
/// <c>WasapiOut</c>: WASAPI shared-mode playback expects the provider's format to
/// match the output device's own mix format (commonly 48kHz stereo float),
/// which would mean querying the device and re-wrapping in a second resampler
/// purely for playback — <c>WaveOutEvent</c> handles arbitrary PCM formats
/// directly and is the standard NAudio choice for exactly this "I have PCM,
/// just play it" case. Capture uses WASAPI directly (<see cref="RealtimeMicCapture"/>)
/// because that's where format precision actually mattered for this port.
/// </summary>
public sealed class RealtimePlaybackSink : IDisposable
{
    private readonly WaveOutEvent _output;
    private readonly BufferedWaveProvider _buffer;
    private bool _disposed;

    public RealtimePlaybackSink()
    {
        _buffer = new BufferedWaveProvider(RealtimeAudioFormat.WaveFormat)
        {
            DiscardOnBufferOverflow = false,
            BufferDuration = TimeSpan.FromSeconds(30),
        };
        _output = new WaveOutEvent();
        _output.Init(_buffer);
        _output.Play();
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
