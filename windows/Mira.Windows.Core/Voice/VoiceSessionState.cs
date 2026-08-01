namespace Mira.Windows.Core.Voice;

/// <summary>Mirrors the observable states of macOS's <c>RealtimeVoiceService.state</c>, narrowed to what push-to-talk mode (this port's scope) actually uses.</summary>
public enum VoiceSessionState
{
    Idle,
    Connecting,
    Listening,
    Thinking,
    Speaking,
    Error,
}
