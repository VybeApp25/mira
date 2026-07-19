namespace Mira.Windows.Core.Chat;

/// <summary>
/// Same cross-project bridging pattern as <see cref="NowPlayingBridge"/>: Core
/// is a plain net10.0 TFM and can't reference WinRT's
/// <c>Windows.Media.SpeechRecognition</c> directly, so the actual
/// <c>SpeechRecognizer</c>-backed implementation lives in
/// <c>Mira.Windows.App/Shell/WakeWordService.cs</c> and registers itself here
/// once at startup. Core only needs to start/pause it and hear about
/// detections — it never touches the WinRT types themselves.
/// </summary>
public interface IWakeWordBridge
{
    bool IsListening { get; }
    void Start();
    void Pause();
    event EventHandler? Detected;
}

public static class WakeWordBridge
{
    public static IWakeWordBridge? Current { get; set; }
}
