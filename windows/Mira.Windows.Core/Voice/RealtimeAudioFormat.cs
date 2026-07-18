using NAudio.Wave;

namespace Mira.Windows.Core.Voice;

/// <summary>
/// The exact audio format the OpenAI Realtime API (model <c>gpt-realtime</c>)
/// expects/produces on both directions — confirmed in
/// Mira/Services/RealtimeVoiceService.swift's <c>buildSessionUpdate</c>:
/// <c>"format": {"type": "audio/pcm", "rate": 24000}</c> for both
/// <c>session.audio.input</c> and <c>session.audio.output</c>. 16-bit signed PCM,
/// mono, 24kHz — matches the Swift client's own capture/playback format exactly
/// (it converts from the hardware's native format to this on the way in, and
/// from this to Float32 for playback on the way out; the Windows client does the
/// analogous conversions via NAudio's resampler instead of AVAudioConverter).
/// </summary>
public static class RealtimeAudioFormat
{
    public const int SampleRate = 24_000;
    public const int Channels = 1;
    public const int BitsPerSample = 16;

    public static WaveFormat WaveFormat { get; } = new(SampleRate, BitsPerSample, Channels);
}
