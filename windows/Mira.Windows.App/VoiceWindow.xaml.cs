using System.Windows;
using Mira.Windows.Core.Voice;

namespace Mira.Windows.App;

/// <summary>
/// Phase 4's push-to-talk voice window: hold the button to record, release to
/// send the turn. Wake phrase and always-on listening are deliberately not
/// implemented — see RealtimeVoiceService's doc comment for the full list of
/// what this port narrows relative to the macOS original.
/// </summary>
public partial class VoiceWindow : Window
{
    private bool _connected;

    public VoiceWindow()
    {
        InitializeComponent();
        RealtimeVoiceService.Shared.StateChanged += OnStateChanged;
        RealtimeVoiceService.Shared.AssistantTranscriptDelta += OnTranscriptDelta;
        RealtimeVoiceService.Shared.ErrorOccurred += OnError;
    }

    private void OnStateChanged(VoiceSessionState state) => Dispatcher.Invoke(() =>
    {
        StatusText.Text = state switch
        {
            VoiceSessionState.Idle => _connected ? "Ready — hold the button and speak" : "Not connected",
            VoiceSessionState.Connecting => "Connecting…",
            VoiceSessionState.Listening => "Listening…",
            VoiceSessionState.Thinking => "Thinking…",
            VoiceSessionState.Speaking => "Speaking…",
            VoiceSessionState.Error => "Error",
            _ => StatusText.Text,
        };
        PttButton.IsEnabled = _connected && state == VoiceSessionState.Idle;
        if (state == VoiceSessionState.Thinking) TranscriptText.Text = "";
    });

    private void OnTranscriptDelta(string delta) => Dispatcher.Invoke(() => TranscriptText.Text += delta);

    private void OnError(string message) => Dispatcher.Invoke(() =>
    {
        StatusText.Text = "Error";
        TranscriptText.Text = message;
        _connected = false;
        ConnectButton.Content = "Connect";
        PttButton.IsEnabled = false;
    });

    private async void ConnectButton_Click(object sender, RoutedEventArgs e)
    {
        if (_connected)
        {
            ConnectButton.IsEnabled = false;
            await RealtimeVoiceService.Shared.DisconnectAsync();
            _connected = false;
            ConnectButton.Content = "Connect";
            ConnectButton.IsEnabled = true;
            StatusText.Text = "Not connected";
        }
        else
        {
            ConnectButton.IsEnabled = false;
            await RealtimeVoiceService.Shared.ConnectAsync();
            _connected = RealtimeVoiceService.Shared.State != VoiceSessionState.Error;
            ConnectButton.Content = _connected ? "Disconnect" : "Connect";
            ConnectButton.IsEnabled = true;
        }
    }

    private async void PttButton_MouseDown(object sender, System.Windows.Input.MouseButtonEventArgs e)
        => await RealtimeVoiceService.Shared.BeginRecordingAsync();

    private async void PttButton_MouseUp(object sender, System.Windows.Input.MouseButtonEventArgs e)
        => await RealtimeVoiceService.Shared.EndRecordingAndCommitAsync();

    private async void Window_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        RealtimeVoiceService.Shared.StateChanged -= OnStateChanged;
        RealtimeVoiceService.Shared.AssistantTranscriptDelta -= OnTranscriptDelta;
        RealtimeVoiceService.Shared.ErrorOccurred -= OnError;
        if (_connected) await RealtimeVoiceService.Shared.DisconnectAsync();
    }
}
