using System.Net.Http.Headers;
using System.Net.WebSockets;
using System.Text;
using Mira.Contracts.MintRealtimeToken;
using Mira.Contracts.ReportVoiceUsage;
using Mira.Windows.Core.Auth;
using Mira.Windows.Core.Config;
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
/// Deliberately narrower than the Swift original, matching
/// docs/windows/IMPLEMENTATION_PLAN.md Phase 4's scope:
/// <list type="bullet">
/// <item><b>Push-to-talk only</b> — no always-on/server_vad mode, and no wake
/// phrase (macOS's wake word depends on Apple's on-device Speech framework,
/// which has no Windows equivalent — see docs/windows/SECURITY_AND_PRIVACY.md
/// and the Phase 0 audit; it needs its own design spike, not a port).</item>
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
/// </list>
/// </summary>
public sealed class RealtimeVoiceService : IDisposable
{
    public static RealtimeVoiceService Shared { get; } = new();

    private const string Model = "gpt-realtime";
    private const string SystemInstructions =
        "You are Mira, a helpful voice assistant running on Windows. Keep responses concise and conversational.";

    private ClientWebSocket? _ws;
    private RealtimeMicCapture? _mic;
    private RealtimePlaybackSink? _playback;
    private CancellationTokenSource? _receiveLoopCts;
    private DateTimeOffset _sessionStartedAt;
    private bool _sessionReady;

    public VoiceSessionState State { get; private set; } = VoiceSessionState.Idle;

    public event Action<VoiceSessionState>? StateChanged;
    public event Action<string>? AssistantTranscriptDelta;
    public event Action<string>? ErrorOccurred;

    private RealtimeVoiceService() { }

    // ---- Session lifecycle ----------------------------------------------------

    public async Task ConnectAsync(CancellationToken ct = default)
    {
        if (State != VoiceSessionState.Idle) return;
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
            ErrorOccurred?.Invoke(ex.Message);
            SetState(VoiceSessionState.Idle);
        }
    }

    public async Task DisconnectAsync()
    {
        var seconds = _sessionStartedAt == default ? 0 : (int)(DateTimeOffset.UtcNow - _sessionStartedAt).TotalSeconds;
        Teardown();
        if (seconds > 0) await ReportVoiceUsageAsync(seconds);
        SetState(VoiceSessionState.Idle);
    }

    private void Teardown()
    {
        _mic?.Dispose();
        _mic = null;
        _playback?.Dispose();
        _playback = null;
        _receiveLoopCts?.Cancel();
        _receiveLoopCts = null;
        try { _ws?.Abort(); } catch { /* already closed */ }
        _ws?.Dispose();
        _ws = null;
        _sessionReady = false;
        _sessionStartedAt = default;
    }

    // ---- Push-to-talk ----------------------------------------------------------

    /// <summary>
    /// Call on push-to-talk key/button DOWN. Builds and starts
    /// <see cref="RealtimeMicCapture"/> on a ThreadPool thread rather than
    /// whatever thread calls this — WPF's UI thread is STA, and WASAPI's
    /// <c>IAudioClient</c> COM object gets apartment-bound to whichever thread
    /// constructs it; NAudio then drives it from its own internal capture
    /// thread, which throws <c>RPC_E_WRONG_THREAD</c> the moment real capture
    /// starts if that object was created on an STA thread. This is invisible in
    /// a console/test host (default MTA) — confirmed both an isolated capture
    /// test and a full connect-record-reply test pass cleanly there — and only
    /// bites when this is called directly from a WPF button handler, which is
    /// exactly the reported crash ("connect then hold to talk and it
    /// crashed"). <see cref="RealtimePlaybackSink"/> doesn't need the same
    /// treatment: it's already constructed from the WebSocket receive loop's
    /// background <c>Task.Run</c>, never the UI thread.
    /// </summary>
    public async Task BeginRecordingAsync()
    {
        if (!_sessionReady || State != VoiceSessionState.Idle || _mic is not null) return;
        SetState(VoiceSessionState.Listening);
        _mic = await Task.Run(() =>
        {
            var mic = new RealtimeMicCapture();
            mic.OnPcm16Chunk += (buf, count) =>
            {
                var b64 = Convert.ToBase64String(buf, 0, count);
                _ = EmitAsync(new JObject { ["type"] = "input_audio_buffer.append", ["audio"] = b64 });
            };
            mic.Start();
            return mic;
        });
    }

    /// <summary>Call on push-to-talk key/button UP — commits the turn and requests a response.</summary>
    public async Task EndRecordingAndCommitAsync()
    {
        if (_mic is null) return;
        _mic.Stop();
        _mic.Dispose();
        _mic = null;

        await EmitAsync(new JObject { ["type"] = "input_audio_buffer.commit" });
        await EmitAsync(new JObject { ["type"] = "response.create" });
    }

    // ---- Ephemeral token mint --------------------------------------------------

    private static async Task<string> MintEphemeralTokenAsync(CancellationToken ct)
    {
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
        catch (WebSocketException ex) { ErrorOccurred?.Invoke(ex.Message); }
    }

    private void HandleEvent(string json)
    {
        JObject evt;
        try { evt = JObject.Parse(json); }
        catch { return; }

        switch ((string?)evt["type"])
        {
            case "session.created":
                _playback = new RealtimePlaybackSink();
                _ = SendSessionUpdateAsync();
                break;

            case "session.updated":
                _sessionReady = true;
                SetState(VoiceSessionState.Idle);
                break;

            case "response.created":
                SetState(VoiceSessionState.Thinking);
                break;

            case "response.output_audio.delta":
                if ((string?)evt["delta"] is { } b64 && b64.Length > 0)
                {
                    var bytes = Convert.FromBase64String(b64);
                    _playback?.Enqueue(bytes, bytes.Length);
                    if (State == VoiceSessionState.Thinking) SetState(VoiceSessionState.Speaking);
                }
                break;

            case "response.output_audio_transcript.delta":
                AssistantTranscriptDelta?.Invoke((string?)evt["delta"] ?? "");
                break;

            case "response.done":
                SetState(VoiceSessionState.Idle);
                break;

            case "error":
                ErrorOccurred?.Invoke((string?)evt["error"]?["message"] ?? "Realtime API error");
                break;
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
                    // Push-to-talk: the button hold/release defines the turn, so
                    // server VAD must be off (null) — matches the Swift original's
                    // exact rationale (see buildSessionUpdate's comment).
                    ["turn_detection"] = JValue.CreateNull(),
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

    private async Task EmitAsync(JObject evt)
    {
        if (_ws is not { State: WebSocketState.Open }) return;
        var bytes = Encoding.UTF8.GetBytes(evt.ToString(Newtonsoft.Json.Formatting.None));
        await _ws.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
    }

    private void SetState(VoiceSessionState state)
    {
        State = state;
        StateChanged?.Invoke(state);
    }

    public void Dispose() => Teardown();
}
