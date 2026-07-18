using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Mira.Windows.Core.Voice;

/// <summary>
/// The Windows equivalent of the capture half of
/// Mira/Services/RealtimeVoiceService.swift's <c>AVAudioEngine</c> tap +
/// <c>encodeAndSend</c> — captures the default microphone via WASAPI (shared
/// mode, the device's native mix format, typically 48kHz stereo float),
/// downmixes to mono and resamples to <see cref="RealtimeAudioFormat"/> (24kHz
/// mono 16-bit PCM), then raises <see cref="OnPcm16Chunk"/> with ready-to-send
/// PCM16 bytes — the caller base64-encodes and sends them as
/// <c>input_audio_buffer.append</c> events, exactly like the Swift original.
///
/// Uses NAudio's pure-managed <see cref="WdlResamplingSampleProvider"/>, NOT
/// <c>MediaFoundationResampler</c> — confirmed directly that the
/// Media-Foundation/COM-based resampler crashes the process with an unmanaged
/// access violation (0xC0000005 inside <c>IMFTransform.ProcessOutput</c>) the
/// moment real captured audio reaches it from WASAPI's dedicated capture
/// thread, even after <c>MediaFoundationApi.Startup()</c> — almost certainly a
/// COM apartment/thread-affinity issue between the MF transform (created on the
/// constructing thread) and the callback thread WASAPI capture invokes it from.
/// The WDL resampler is pure managed code with no COM/thread-affinity to get
/// wrong, and is NAudio's own recommended alternative for exactly this
/// real-time-capture-callback scenario.
/// </summary>
public sealed class RealtimeMicCapture : IDisposable
{
    private readonly WasapiCapture _capture;
    private readonly BufferedWaveProvider _sourceBuffer;
    private readonly ISampleProvider _resampled;
    private readonly byte[] _readBuffer = new byte[8192];
    private readonly float[] _floatReadBuffer = new float[4096];
    private bool _disposed;

    /// <summary>Fires with resampled 24kHz mono 16-bit PCM bytes as they become available.</summary>
    public event Action<byte[], int>? OnPcm16Chunk;

    public RealtimeMicCapture()
    {
        _capture = new WasapiCapture(); // default communications-preferred input device, shared mode
        _sourceBuffer = new BufferedWaveProvider(_capture.WaveFormat)
        {
            // ReadFully defaults to true, which pads reads with silence forever
            // instead of returning fewer bytes (or 0) once the buffer is drained —
            // confirmed directly: with it left at the default, OnDataAvailable's
            // drain loop below never saw a non-positive count and spun forever,
            // hanging the WASAPI capture thread and, with it, StopRecording()
            // (and the whole process) on the very first real capture callback.
            ReadFully = false,
            DiscardOnBufferOverflow = true,
            BufferDuration = TimeSpan.FromSeconds(5),
        };

        ISampleProvider samples = _sourceBuffer.ToSampleProvider();
        if (samples.WaveFormat.Channels > 1)
            samples = new StereoToMonoSampleProvider(samples) { LeftVolume = 0.5f, RightVolume = 0.5f };
        _resampled = samples.WaveFormat.SampleRate == RealtimeAudioFormat.SampleRate
            ? samples
            : new WdlResamplingSampleProvider(samples, RealtimeAudioFormat.SampleRate);

        _capture.DataAvailable += OnDataAvailable;
    }

    public void Start() => _capture.StartRecording();

    public void Stop() => _capture.StopRecording();

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        _sourceBuffer.AddSamples(e.Buffer, 0, e.BytesRecorded);

        // Pull everything now available as float samples, convert to 16-bit PCM.
        int samplesRead;
        while ((samplesRead = _resampled.Read(_floatReadBuffer, 0, _floatReadBuffer.Length)) > 0)
        {
            var byteCount = samplesRead * 2;
            for (var i = 0; i < samplesRead; i++)
            {
                var clamped = Math.Clamp(_floatReadBuffer[i], -1f, 1f);
                var pcm16 = (short)(clamped * short.MaxValue);
                _readBuffer[i * 2] = (byte)(pcm16 & 0xFF);
                _readBuffer[i * 2 + 1] = (byte)((pcm16 >> 8) & 0xFF);
            }
            OnPcm16Chunk?.Invoke(_readBuffer, byteCount);
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _capture.DataAvailable -= OnDataAvailable;
        try { _capture.StopRecording(); } catch { /* already stopped */ }
        _capture.Dispose();
    }
}
