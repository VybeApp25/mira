using Windows.Media.SpeechRecognition;
using Mira.Windows.Core.Chat;

namespace Mira.Windows.App.Shell;

/// <summary>
/// The Windows equivalent of Mira/Services/WakeWordService.swift — always-on,
/// low-power wake word detection using WinRT's on-device
/// <see cref="SpeechRecognizer"/>. When a trigger phrase is heard, pauses
/// itself and raises <see cref="Detected"/> (the Windows equivalent of Mac's
/// <c>.miraActivateVoice</c> notification post) so <c>IslandWindow</c> can
/// open the voice window, mirroring NotchManager.swift's wiring exactly.
///
/// Unlike Mac's SFSpeechRecognizer (which does open dictation and matches
/// trigger phrases as substrings of whatever it transcribes),
/// <see cref="SpeechRecognitionListConstraint"/> biases the recognizer to
/// only the trigger phrase list up front — closer to keyword spotting than
/// free dictation, so this is arguably tighter than Mac's approach while
/// still checking <see cref="WakeWordSettings.MatchesTrigger"/> against the
/// result text for parity/safety.
///
/// Implements <see cref="IWakeWordBridge"/> so <c>IslandWindow</c> (via Core's
/// bridge indirection, needed because Core can't reference WinRT directly)
/// can start/pause it and subscribe to detections without touching
/// <see cref="SpeechRecognizer"/> itself.
/// </summary>
public sealed class WakeWordService : IWakeWordBridge
{
    public static WakeWordService Shared { get; } = new();

    private SpeechRecognizer? _recognizer;
    private bool _enabled;
    private bool _cycleRunning;

    public bool IsListening { get; private set; }

    /// <summary>Fires from a WinRT callback thread on detection — subscribers must marshal to their own dispatcher.</summary>
    public event EventHandler? Detected;

    private WakeWordService() { }

    public void Start()
    {
        if (_enabled) return;
        if (!WakeWordSettings.IsEnabled) return;
        _enabled = true;
        _ = BeginCycleAsync();
    }

    public void Pause()
    {
        if (!_enabled) return;
        _enabled = false;
        Teardown();
    }

    private async Task BeginCycleAsync()
    {
        if (!_enabled || _cycleRunning) return;
        _cycleRunning = true;

        try
        {
            _recognizer = new SpeechRecognizer();
            var constraint = new SpeechRecognitionListConstraint(WakeWordSettings.Triggers, "wakeWord");
            _recognizer.Constraints.Add(constraint);

            var compileResult = await _recognizer.CompileConstraintsAsync();
            if (compileResult.Status != SpeechRecognitionResultStatus.Success || !_enabled)
            {
                Teardown();
                ScheduleRestart();
                return;
            }

            _recognizer.ContinuousRecognitionSession.ResultGenerated += OnResultGenerated;
            _recognizer.ContinuousRecognitionSession.Completed += OnSessionCompleted;

            await _recognizer.ContinuousRecognitionSession.StartAsync();
            IsListening = true;
        }
        catch
        {
            Teardown();
            ScheduleRestart();
        }
    }

    private void OnResultGenerated(SpeechContinuousRecognitionSession sender, SpeechContinuousRecognitionResultGeneratedEventArgs args)
    {
        if (!_enabled) return;
        if (args.Result.Confidence == SpeechRecognitionConfidence.Rejected) return;
        if (!WakeWordSettings.MatchesTrigger(args.Result.Text)) return;

        HandleDetection();
    }

    private void OnSessionCompleted(SpeechContinuousRecognitionSession sender, SpeechContinuousRecognitionCompletedEventArgs args)
    {
        // Mirrors WakeWordService.swift's natural ~60s on-device session end --
        // tear down and restart the cycle rather than treating this as a failure.
        _cycleRunning = false;
        if (!_enabled) return;
        Teardown();
        ScheduleRestart();
    }

    private void HandleDetection()
    {
        Pause();
        Detected?.Invoke(this, EventArgs.Empty);
    }

    private void ScheduleRestart()
    {
        if (!_enabled) return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(1200);
            if (_enabled) await BeginCycleAsync();
        });
    }

    private void Teardown()
    {
        if (_recognizer is not null)
        {
            _recognizer.ContinuousRecognitionSession.ResultGenerated -= OnResultGenerated;
            _recognizer.ContinuousRecognitionSession.Completed -= OnSessionCompleted;
            try { _ = _recognizer.ContinuousRecognitionSession.StopAsync(); } catch { /* already stopped */ }
            _recognizer.Dispose();
            _recognizer = null;
        }
        _cycleRunning = false;
        IsListening = false;
    }
}
