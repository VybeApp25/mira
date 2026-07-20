using System.Net.Http.Headers;
using System.Net.WebSockets;
using System.Text;
using Mira.Contracts.MintRealtimeToken;
using Mira.Contracts.ReportVoiceUsage;
using Mira.Windows.Core.Audio;
using Mira.Windows.Core.Auth;
using Mira.Windows.Core.Config;
using Mira.Windows.Core.Vision;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Voice;

/// <summary>
/// The Windows equivalent of macOS's <c>RealtimeVoiceService</c>
/// (Mira/Services/RealtimeVoiceService.swift) — connects to OpenAI's Realtime API
/// (<c>wss://api.openai.com/v1/realtime?model=gpt-realtime</c>) via a short-lived
/// ephemeral token minted through the existing <c>mint-realtime-token</c> Supabase
/// Edge Function (unchanged — the server treats this client identically to the
/// Mac one), and reports session duration through the existing
/// <c>report-voice-usage</c> function on teardown.
///
/// Uses <c>server_vad</c> turn detection (threshold 0.65, prefix_padding_ms 300,
/// silence_duration_ms 400 — the exact values from the Swift original's
/// <c>buildSessionUpdate</c>) for every session, not only an "always-on" mode:
/// Mac only enables server_vad when <c>isAlwaysOn</c> is true, and otherwise
/// requires holding a push-to-talk key to define the turn. This port
/// deliberately generalizes that — every Windows voice session (wake-word,
/// mic-button, or the persistent Always-On toggle) is turn-detected
/// automatically, since Windows has no literal hold-a-key PTT gesture and the
/// explicit ask this session was to never require a manual tap to end a turn.
/// <see cref="IsAlwaysOnActive"/> only controls whether a session is started
/// persistently (mirroring <c>connectAlwaysOn()</c>) rather than only on
/// trigger — it does not change the turn-detection mechanism.
///
/// Also deliberately narrower than the Swift original, matching
/// docs/windows/IMPLEMENTATION_PLAN.md Phase 4's original scope:
/// <list type="bullet">
/// <item><b>No tool-calling.</b> The Swift session.update declares
/// <c>MiraToolService.definitions</c> so the model can invoke Mira's ~35 tools
/// mid-conversation; no such tool surface exists on Windows yet, so this port's
/// session.update omits <c>tools</c>/<c>tool_choice</c> entirely — the model
/// simply won't attempt to call anything.</item>
/// <item><b>No screen-context injection.</b> The Swift instructions string
/// includes <c>ContextService.shared.buildPromptBlock()</c> (frontmost app,
/// clipboard, battery, etc.); this port uses a static system prompt since that
/// context-gathering service doesn't exist on Windows yet.</item>
/// <item><b>Simplified playback-drained detection.</b> The Swift original
/// schedules a silent "sentinel" audio buffer and gets an exact completion
/// callback when it plays; this port polls <see cref="RealtimePlaybackSink.IsDrained"/>
/// instead — see that class's doc comment.</item>
/// <item><b>No output-route-aware barge-in.</b> The Swift original only keeps
/// streaming the mic while Mira is speaking on external output (headphones),
/// since on built-in speakers her own voice would echo back and self-interrupt.
/// This port has no equivalent output-route detection, so it simplifies to
/// always suppressing the mic while <see cref="VoiceSessionState.Speaking"/> —
/// safe on any output device, at the cost of not supporting barge-in.</item>
/// </list>
/// </summary>
public sealed class RealtimeVoiceService : IDisposable
{
    public static RealtimeVoiceService Shared { get; } = new();

    private const string Model = "gpt-realtime";
    private const string SystemInstructions =
        "You are Mira, a helpful voice assistant running on Windows. Keep responses concise and conversational. "
        + "A screenshot of the user's current screen is attached at the start of each turn, so you can see and reference what they're looking at.";

    // Mirrors RealtimeVoiceService.swift's buildSessionUpdate turn_detection block exactly.
    private const decimal VadThreshold = 0.65m;
    private const int VadPrefixPaddingMs = 300;
    private const int VadSilenceDurationMs = 400;

    // Mirrors the Swift original's 0.8s suppressMicUntil settle window after
    // playback drains, so speaker bleed can't immediately re-trigger the VAD.
    private static readonly TimeSpan PostSpeechSettle = TimeSpan.FromMilliseconds(800);

    private ClientWebSocket? _ws;
    private RealtimeMicCapture? _mic;
    private RealtimePlaybackSink? _playback;
    private CancellationTokenSource? _receiveLoopCts;
    private CancellationTokenSource? _drainWaitCts;
    private DateTimeOffset _sessionStartedAt;
    private DateTimeOffset _suppressMicUntil = DateTimeOffset.MinValue;

    public VoiceSessionState State { get; private set; } = VoiceSessionState.Idle;

    /// <summary>Mirrors <c>isAlwaysOnActive</c> — true while a persistent (Settings-toggle-driven) session is meant to stay open, as opposed to a one-off wake-word/mic-button-triggered session.</summary>
    public bool IsAlwaysOnActive { get; private set; }

    public event Action<VoiceSessionState>? StateChanged;
    public event Action<string>? AssistantTranscriptDelta;
    public event Action<string>? ErrorOccurred;

    /// <summary>
    /// Fires with a running count of raw mic chunks actually sent this turn —
    /// added as a diagnostic after a user report of "connects fine, but
    /// holding to talk does nothing": there was previously no visible signal
    /// distinguishing "the mic captured nothing" from "audio was sent but the
    /// model's reply was empty" from "the round trip never happened at all."
    /// </summary>
    public event Action<int>? ChunkSent;

    /// <summary>
    /// A non-fatal diagnostic message, separate from <see cref="ErrorOccurred"/>
    /// (which the UI treats as session-ending) — e.g. "no audio captured this
    /// turn." The session stays connected; this is purely informational.
    /// </summary>
    public event Action<string>? Warning;

    private int _chunksSentThisTurn;
    private bool _receivedAudioThisTurn;

    private RealtimeVoiceService() { }

    // ---- Session lifecycle ----------------------------------------------------

    /// <summary>Opens a one-off voice session (wake word or the mic button) — ends when the user closes it.</summary>
    public async Task ConnectAsync(CancellationToken ct = default)
    {
        if (State != VoiceSessionState.Idle) return;
        await OpenConnectionAsync(ct);
    }

    /// <summary>
    /// Opens a persistent session mirroring the Swift original's <c>connectAlwaysOn()</c> —
    /// used by the Always-On Settings toggle, both at app launch (if already enabled)
    /// and when the user flips the toggle on live.
    /// </summary>
    public async Task ConnectAlwaysOnAsync(CancellationToken ct = default)
    {
        if (IsAlwaysOnActive) return;
        if (State != VoiceSessionState.Idle) Teardown(); // close any existing one-off session first
        IsAlwaysOnActive = true;
        await OpenConnectionAsync(ct);
    }

    private async Task OpenConnectionAsync(CancellationToken ct)
    {
        SetState(VoiceSessionState.Connecting);

        try
        {
            var ephemeralToken = await MintEphemeralTokenAsync(ct);

            _ws = new ClientWebSocket();
            _ws.Options.SetRequestHeader("Authorization", $"Bearer {ephemeralToken}");
            await _ws.ConnectAsync(new Uri($"wss://api.openai.com/v1/realtime?model={Model}"), ct);

            _sessionStartedAt = DateTimeOffset.UtcNow;
            _receiveLoopCts = new CancellationTokenSource();
            _ = Task.Run(() => ReceiveLoopAsync(_receiveLoopCts.Token), CancellationToken.None);
        }
        catch (Exception ex)
        {
            IsAlwaysOnActive = false;
            ErrorOccurred?.Invoke(ex.Message);
            SetState(VoiceSessionState.Idle);
        }
    }

    public async Task DisconnectAsync()
    {
        var seconds = _sessionStartedAt == default ? 0 : (int)(DateTimeOffset.UtcNow - _sessionStartedAt).TotalSeconds;
        IsAlwaysOnActive = false;
        Teardown();
        if (seconds > 0) await ReportVoiceUsageAsync(seconds);
        SetState(VoiceSessionState.Idle);
    }

    private void Teardown()
    {
        _drainWaitCts?.Cancel();
        _drainWaitCts = null;
        _mic?.Dispose();
        _mic = null;
        _playback?.Dispose();
        _playback = null;
        _receiveLoopCts?.Cancel();
        _receiveLoopCts = null;
        try { _ws?.Abort(); } catch { /* already closed */ }
        _ws?.Dispose();
        _ws = null;
        _sessionStartedAt = default;
        _suppressMicUntil = DateTimeOffset.MinValue;
    }

    // ---- Continuous mic capture (server_vad decides turn boundaries) ----------

    /// <summary>
    /// Starts the mic once, right after the session reports ready — mirrors the
    /// Swift original's <c>startCapture()</c> call from <c>session.updated</c>.
    /// Runs continuously for the life of the session; server-side VAD (not a
    /// manual begin/end gesture) decides when a user utterance starts and ends.
    /// Constructing <see cref="RealtimeMicCapture"/> here (inside the WebSocket
    /// receive loop's background <c>Task.Run</c>, never the WPF UI thread) avoids
    /// the STA/MTA WASAPI apartment mismatch documented on <see cref="RealtimeMicCapture"/>
    /// itself.
    /// </summary>
    private void StartContinuousMicCapture()
    {
        if (_mic is not null) return;
        var mic = new RealtimeMicCapture(AudioDeviceSettings.PreferredInputDeviceId);
        mic.OnPcm16Chunk += (buf, count) =>
        {
            // Mirrors the Swift original's "don't feed the mic back into itself while
            // Mira is speaking" guard, simplified to always-suppress (see this class's
            // own doc comment on why output-route-aware barge-in isn't ported), plus
            // the post-speech settle window that absorbs any trailing speaker bleed.
            if (State == VoiceSessionState.Speaking) return;
            if (DateTimeOffset.UtcNow < _suppressMicUntil) return;

            var b64 = Convert.ToBase64String(buf, 0, count);
            _ = EmitAsync(new JObject { ["type"] = "input_audio_buffer.append", ["audio"] = b64 })
                .ContinueWith(t =>
                {
                    if (t.Result) ChunkSent?.Invoke(++_chunksSentThisTurn);
                }, TaskScheduler.Default);
        };
        mic.Start();
        _mic = mic;
    }

    // ---- Ephemeral token mint --------------------------------------------------

    private static async Task<string> MintEphemeralTokenAsync(CancellationToken ct)
    {
        // Renews the Supabase session first if it's stale -- mirrors the Swift
        // original's openSocketAsync calling ensureFreshToken() before minting.
        // Confirmed live as the actual cause of a real "Couldn't start voice mode:
        // {"code":"UNAUTHORIZED_ASYMMETRIC_JWT","message":"Invalid JWT"}" error:
        // SupabaseService's own 120s proactive-refresh timer (see its
        // ScheduleAutoRefresh doc comment for this exact failure signature)
        // covers most cases, but doesn't cover a token that expired in the gap
        // right before this specific mint call -- this is the same belt-and-
        // suspenders check Mac takes for exactly this endpoint.
        await SupabaseService.Shared.EnsureFreshTokenAsync(ct: ct);

        using var http = new HttpClient();
        using var req = new HttpRequestMessage(HttpMethod.Post, $"{MiraConfig.SupabaseUrl}/functions/v1/mint-realtime-token");
        req.Headers.Add("apikey", MiraConfig.SupabaseAnonKey);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", SupabaseService.CachedAccessToken);
        req.Content = new StringContent(new JObject { ["voice"] = "alloy" }.ToString(Newtonsoft.Json.Formatting.None),
            Encoding.UTF8, "application/json");

        using var resp = await http.SendAsync(req, ct);
        var text = await resp.Content.ReadAsStringAsync(ct);
        if (!resp.IsSuccessStatusCode)
            throw new InvalidOperationException(resp.StatusCode == System.Net.HttpStatusCode.TooManyRequests
                ? "Daily voice limit reached — upgrade for more."
                : $"Couldn't start voice mode: {text}");

        var parsed = MintRealtimeTokenResponse.FromJson(text);
        if (string.IsNullOrEmpty(parsed.Token)) throw new InvalidOperationException("Couldn't start voice mode: no token returned.");
        return parsed.Token;
    }

    private static async Task ReportVoiceUsageAsync(int seconds)
    {
        try
        {
            using var http = new HttpClient();
            using var req = new HttpRequestMessage(HttpMethod.Post, $"{MiraConfig.SupabaseUrl}/functions/v1/report-voice-usage");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", SupabaseService.CachedAccessToken);
            req.Content = new StringContent(new ReportVoiceUsageRequest { Seconds = seconds }.ToJson(), Encoding.UTF8, "application/json");
            await http.SendAsync(req);
        }
        catch
        {
            // Best-effort, mirrors the Swift original's fire-and-forget metering.
        }
    }

    // ---- WebSocket receive loop / event dispatch -------------------------------

    private async Task ReceiveLoopAsync(CancellationToken ct)
    {
        var buffer = new byte[16 * 1024];
        var messageBuilder = new StringBuilder();

        try
        {
            while (_ws?.State == WebSocketState.Open && !ct.IsCancellationRequested)
            {
                messageBuilder.Clear();
                WebSocketReceiveResult result;
                do
                {
                    result = await _ws.ReceiveAsync(buffer, ct);
                    if (result.MessageType == WebSocketMessageType.Close) return;
                    messageBuilder.Append(Encoding.UTF8.GetString(buffer, 0, result.Count));
                } while (!result.EndOfMessage);

                HandleEvent(messageBuilder.ToString());
            }
        }
        catch (OperationCanceledException) { /* expected on teardown */ }
        catch (WebSocketException ex)
        {
            ErrorOccurred?.Invoke(ex.Message);
            SetState(VoiceSessionState.Idle);
        }
        catch (Exception ex)
        {
            // Anything unexpected here previously killed this background loop
            // silently (nobody awaits the Task.Run that started it) -- confirmed
            // directly that this left the UI stuck showing "Connecting..." forever
            // with zero feedback whenever an event handler threw. Now it at least
            // surfaces an error and releases the session back to Idle instead of
            // hanging indefinitely.
            ErrorOccurred?.Invoke($"Voice session error: {ex.Message}");
            SetState(VoiceSessionState.Idle);
        }
    }

    private void HandleEvent(string json)
    {
        JObject evt;
        try { evt = JObject.Parse(json); }
        catch { return; }

        try
        {
            DispatchEvent(evt);
        }
        catch (Exception ex)
        {
            ErrorOccurred?.Invoke($"Voice session error handling '{(string?)evt["type"]}': {ex.Message}");
            SetState(VoiceSessionState.Idle);
        }
    }

    private void DispatchEvent(JObject evt)
    {
        switch ((string?)evt["type"])
        {
            case "session.created":
                _playback = new RealtimePlaybackSink(AudioDeviceSettings.PreferredOutputDeviceId);
                _ = SendSessionUpdateAsync();
                break;

            case "session.updated":
                StartContinuousMicCapture();
                // Cold-start turn has no speech_started yet -- attach the screen for the first question.
                _ = SendScreenSnapshotAsync();
                SetState(VoiceSessionState.Listening);
                break;

            // ── Server VAD: user speech detected ─────────────────────────────────
            case "input_audio_buffer.speech_started":
                _chunksSentThisTurn = 0;
                // Fresh screenshot for every new utterance, not just the first --
                // mirrors the Swift original's exact two call sites, so Mira's
                // screen context stays current turn to turn, not stale from launch.
                _ = SendScreenSnapshotAsync();
                if (State == VoiceSessionState.Speaking)
                {
                    // Barge-in: discard whatever's still queued for playback and cancel
                    // the in-flight response. Mirrors the Swift original's interrupt path,
                    // simplified since this port doesn't stream the mic during Speaking
                    // (see this class's doc comment) -- kept defensively in case any
                    // trailing audio still slips through.
                    _playback?.ClearPending();
                    _ = EmitAsync(new JObject { ["type"] = "response.cancel" });
                }
                SetState(VoiceSessionState.Listening);
                break;

            // ── Server VAD: user stopped speaking — server auto-commits, no client action needed ──
            case "input_audio_buffer.speech_stopped":
                break;

            case "response.created":
                _receivedAudioThisTurn = false;
                SetState(VoiceSessionState.Thinking);
                break;

            case "response.output_audio.delta":
                if ((string?)evt["delta"] is { } b64 && b64.Length > 0)
                {
                    _receivedAudioThisTurn = true;
                    var bytes = Convert.FromBase64String(b64);
                    _playback?.Enqueue(bytes, bytes.Length);
                    if (State == VoiceSessionState.Thinking) SetState(VoiceSessionState.Speaking);
                }
                break;

            case "response.output_audio_transcript.delta":
                AssistantTranscriptDelta?.Invoke((string?)evt["delta"] ?? "");
                break;

            // Audio stream for this response finished — wait for local playback to
            // actually drain (mirrors the Swift original's sentinel-buffer completion
            // callback, via RealtimePlaybackSink.IsDrained polling) before re-arming
            // the mic, so Mira's own trailing audio can't immediately retrigger VAD.
            case "response.output_audio.done":
                _ = WaitForPlaybackDrainThenListenAsync();
                break;

            case "response.done":
                // Diagnostic added after a user report of "connects fine, but
                // holding to talk does nothing, no reply audio" -- previously
                // this looked identical whether the mic captured real speech,
                // captured silence, or the turn was empty for some other
                // reason. Now at least the empty case says so explicitly
                // instead of just quietly going back to "Ready."
                if (!_receivedAudioThisTurn && _chunksSentThisTurn > 0)
                    Warning?.Invoke($"Sent {_chunksSentThisTurn} audio chunk(s) but got no audio reply back — the mic may have captured only silence. Check Windows' microphone privacy settings and default input device.");
                else if (_chunksSentThisTurn == 0)
                    Warning?.Invoke("No audio was captured to send — check that a microphone is connected and Windows' \"Let desktop apps access your microphone\" setting is on.");
                // A response with no audio at all (tool-only, or an empty turn) never
                // fires response.output_audio.done, so there's nothing to drain --
                // return straight to listening rather than waiting on an event that
                // will never arrive.
                if (!_receivedAudioThisTurn) SetState(VoiceSessionState.Listening);
                break;

            case "error":
                // Mirrors the Swift original's benign-error filtering exactly -- these
                // are ordinary races (cancelling a response that already finished,
                // committing an empty buffer) that server_vad's own automatic
                // commit/cancel timing can produce under normal use, not real failures.
                // Treating them as errors would needlessly kill always-on listening.
                var code = (string?)evt["error"]?["code"] ?? "?";
                var msg = (string?)evt["error"]?["message"] ?? "Realtime API error";
                var benign = code == "response_cancel_not_active"
                          || code == "input_audio_buffer_commit_empty"
                          || msg.Contains("no active response")
                          || msg.Contains("buffer too small");
                if (!benign) ErrorOccurred?.Invoke(msg);
                break;
        }
    }

    private async Task WaitForPlaybackDrainThenListenAsync()
    {
        _drainWaitCts?.Cancel();
        var cts = new CancellationTokenSource();
        _drainWaitCts = cts;

        try
        {
            var deadline = DateTimeOffset.UtcNow.AddSeconds(10);
            while (_playback is not null && !_playback.IsDrained && DateTimeOffset.UtcNow < deadline)
                await Task.Delay(50, cts.Token);

            if (cts.Token.IsCancellationRequested) return;
            if (State != VoiceSessionState.Speaking) return; // superseded by a newer turn, error, or teardown

            _suppressMicUntil = DateTimeOffset.UtcNow + PostSpeechSettle;
            SetState(VoiceSessionState.Listening);
        }
        catch (TaskCanceledException) { /* superseded by a newer turn or teardown */ }
    }

    /// <summary>
    /// Attaches a fresh screenshot as a <c>conversation.item.create</c> input_image
    /// message -- mirrors the Swift original's <c>sendScreenSnapshot()</c> exactly,
    /// including being called both on the cold-start turn and again at the start
    /// of every subsequent utterance. Reuses <see cref="ScreenCapture.CaptureJpeg"/>,
    /// the same GDI-based (<c>CopyFromScreen</c>) capture <c>screen_guidance</c>/
    /// <c>computer_use</c> already use for text chat -- see that class's own doc
    /// comment for the real, known limitation this inherits: exclusive-fullscreen
    /// DirectX games (confirmed live: Marvel Rivals) render outside the desktop
    /// compositor entirely, so GDI's `CopyFromScreen` can only see whatever was on
    /// the desktop underneath, not the live game frame. Best-effort like the Swift
    /// original -- any failure here silently skips this turn's screen context
    /// rather than interrupting the voice turn itself.
    /// </summary>
    private async Task SendScreenSnapshotAsync()
    {
        if (!VoiceScreenContextSettings.IsEnabled) return;
        try
        {
            var jpeg = ScreenCapture.CaptureJpeg();
            if (jpeg is null) return;
            await EmitAsync(new JObject
            {
                ["type"] = "conversation.item.create",
                ["item"] = new JObject
                {
                    ["type"] = "message",
                    ["role"] = "user",
                    ["content"] = new JArray
                    {
                        new JObject
                        {
                            ["type"] = "input_image",
                            ["image_url"] = $"data:image/jpeg;base64,{Convert.ToBase64String(jpeg)}",
                        },
                    },
                },
            });
        }
        catch
        {
            // Best-effort, mirrors the Swift original -- the voice turn proceeds without it.
        }
    }

    private Task SendSessionUpdateAsync()
    {
        var session = new JObject
        {
            ["type"] = "realtime",
            ["instructions"] = SystemInstructions,
            ["output_modalities"] = new JArray { "audio" },
            ["audio"] = new JObject
            {
                ["input"] = new JObject
                {
                    ["format"] = new JObject { ["type"] = "audio/pcm", ["rate"] = RealtimeAudioFormat.SampleRate },
                    ["turn_detection"] = BuildTurnDetectionConfig(),
                },
                ["output"] = new JObject
                {
                    ["format"] = new JObject { ["type"] = "audio/pcm", ["rate"] = RealtimeAudioFormat.SampleRate },
                    ["voice"] = "alloy",
                },
            },
        };
        return EmitAsync(new JObject { ["type"] = "session.update", ["session"] = session });
    }

    /// <summary>
    /// Mirrors RealtimeVoiceService.swift's buildSessionUpdate turn_detection block
    /// exactly (threshold/prefix_padding_ms/silence_duration_ms values included) --
    /// pulled into its own pure method so the exact config shape is directly
    /// testable without a live connection. Unlike the Swift original, this is
    /// unconditional (see this class's doc comment for why).
    /// </summary>
    public static JObject BuildTurnDetectionConfig() => new()
    {
        ["type"] = "server_vad",
        ["threshold"] = VadThreshold,
        ["prefix_padding_ms"] = VadPrefixPaddingMs,
        ["silence_duration_ms"] = VadSilenceDurationMs,
    };

    /// <returns><c>false</c> if the socket wasn't open to send on (a silent no-op previously — the caller now surfaces this instead of leaving it invisible).</returns>
    private async Task<bool> EmitAsync(JObject evt)
    {
        if (_ws is not { State: WebSocketState.Open }) return false;
        var bytes = Encoding.UTF8.GetBytes(evt.ToString(Newtonsoft.Json.Formatting.None));
        await _ws.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
        return true;
    }

    private void SetState(VoiceSessionState state)
    {
        State = state;
        PlayCueForState(state);
        StateChanged?.Invoke(state);
    }

    /// <summary>
    /// Mirrors PillStateModel.swift's <c>setMode</c> calling into
    /// <c>AudioCueService.playModeChange</c> centrally on every mode change,
    /// rather than at each individual call site -- Windows has no separate
    /// PillMode type (that's a Mac-only debounced SwiftUI state layer), so this
    /// maps directly off <see cref="VoiceSessionState"/> instead, using the
    /// exact same sound-per-mode assignments (idle/working have none).
    /// </summary>
    private static void PlayCueForState(VoiceSessionState state)
    {
        switch (state)
        {
            case VoiceSessionState.Listening: AudioCueService.Shared.Play(MiraSound.Enter); break;
            case VoiceSessionState.Thinking: AudioCueService.Shared.Play(MiraSound.SkillUp); break;
            case VoiceSessionState.Speaking: AudioCueService.Shared.PlayTextReceive(); break;
            case VoiceSessionState.Connecting: AudioCueService.Shared.PlayVoiceStart(); break; // intentional no-op, matches Mac
        }
    }

    public void Dispose()
    {
        IsAlwaysOnActive = false;
        Teardown();
    }
}
