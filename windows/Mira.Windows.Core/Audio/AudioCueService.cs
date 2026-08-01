using NAudio.Wave;

namespace Mira.Windows.Core.Audio;

/// <summary>
/// The Windows equivalent of macOS's <c>AudioCueService</c>
/// (Mira/Services/AudioCueService.swift) — Mira's UI sound cues (voice/text
/// open-close chimes, agent lifecycle sounds, skill toggles, etc.), reusing
/// the exact same 16 sound files from the Mac app's own bundle (MP3/WAV
/// aren't platform-specific). One <see cref="AudioFileReader"/>/
/// <see cref="WaveOutEvent"/> pair is preloaded per sound at startup and
/// reused for every play (stop, rewind, replay) — same design as the Swift
/// original's dictionary of preloaded <c>AVAudioPlayer</c>s, and the same
/// reason: avoids the decode/open latency a fresh player would have on every
/// single cue.
///
/// Deliberately not ported: <c>warmHardware()</c> (the Swift original's
/// silent 0-volume priming play to eliminate first-play latency spikes on
/// AVFoundation's audio pipeline) — NAudio's playback path doesn't show the
/// same cold-start latency this was working around, and every sound is
/// already preloaded/initialized at construction here regardless.
/// </summary>
public sealed class AudioCueService
{
    public static AudioCueService Shared { get; } = new();

    private static readonly TimeSpan RateLimitInterval = TimeSpan.FromSeconds(1.5);

    private sealed class Player : IDisposable
    {
        public required AudioFileReader Reader { get; init; }
        public required WaveOutEvent Output { get; init; }
        public void Dispose()
        {
            Output.Dispose();
            Reader.Dispose();
        }
    }

    private readonly Dictionary<MiraSound, Player> _players = new();
    private readonly Dictionary<MiraSound, DateTimeOffset> _lastPlayed = new();
    private readonly object _gate = new();

    private AudioCueService() => Preload();

    private void Preload()
    {
        foreach (var sound in Enum.GetValues<MiraSound>())
        {
            try
            {
                var path = Path.Combine(AppContext.BaseDirectory, "Assets", "Sounds", $"{sound.FileName()}.{sound.FileExtension()}");
                if (!File.Exists(path)) continue;

                var reader = new AudioFileReader(path);
                var output = new WaveOutEvent();
                output.Init(reader);
                _players[sound] = new Player { Reader = reader, Output = output };
            }
            catch
            {
                // Matches the Swift original's own "if let player = try? ..." --
                // a missing or corrupt sound file just means that cue stays silent.
            }
        }
    }

    /// <summary>Plays a cue, rate-limited to once per 1.5s per sound and gated on mute/per-cue settings -- mirrors the Swift original's <c>play(_:)</c> exactly.</summary>
    public void Play(MiraSound sound)
    {
        if (AudioCueSettings.IsMuted || !AudioCueSettings.IsCueEnabled(sound.FileName())) return;

        lock (_gate)
        {
            if (_lastPlayed.TryGetValue(sound, out var last) && DateTimeOffset.UtcNow - last < RateLimitInterval) return;
            _lastPlayed[sound] = DateTimeOffset.UtcNow;

            if (!_players.TryGetValue(sound, out var player)) return;
            try
            {
                if (player.Output.PlaybackState == PlaybackState.Playing) player.Output.Stop();
                player.Reader.Position = 0;
                player.Output.Play();
            }
            catch
            {
                // Best-effort playback -- matches the Swift original's own silent-failure behavior.
            }
        }
    }

    // ---- Named convenience methods (mirrors AudioCueService.swift 1:1) --------

    public void PlayAgentLaunch() => Play(MiraSound.AgentLaunch);
    public void PlayAgentComplete() => Play(MiraSound.AgentDone);
    public void PlayAgentClose() => Play(MiraSound.AgentClose);
    public void PlayAgentBlocked() => Play(MiraSound.SkillDown);
    public void PlayTextOpen() => Play(MiraSound.TextOpen);
    public void PlayTextSend() => Play(MiraSound.TextSend);
    public void PlayTextReceive() => Play(MiraSound.TextReceive);
    public void PlayTextClose() => Play(MiraSound.TextClose);

    /// <summary>Intentionally silent -- matches the Swift original's own comment on <c>playVoiceStart()</c>: "silent — no activation chime on voice start."</summary>
    public void PlayVoiceStart() { }

    public void PlayClarification() => Play(MiraSound.Question);
    public void PlayConnectionQuestion() => Play(MiraSound.ConnectionQuestion);
    public void PlaySkillUp() => Play(MiraSound.SkillUp);
    public void PlaySkillDown() => Play(MiraSound.SkillDown);
}
