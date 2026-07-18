using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Input;
using Mira.Windows.Core.Chat;

namespace Mira.Windows.App;

/// <summary>
/// Phase 3's bare chat window — text in, routed through
/// <see cref="RouterHandler"/>, streamed reply out. Deliberately not the
/// notch/island UI (see docs/windows/IMPLEMENTATION_PLAN.md Phase 6).
/// </summary>
public partial class ChatWindow : Window
{
    private readonly ObservableCollection<ChatBubbleViewModel> _bubbles = new();
    private readonly List<ChatMessage> _history = new();
    private bool _isSending;

    public ChatWindow()
    {
        InitializeComponent();
        MessagesList.ItemsSource = _bubbles;
        InputBox.Focus();
    }

    private async void SendButton_Click(object sender, RoutedEventArgs e) => await SendAsync();

    private async void InputBox_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Enter && !Keyboard.Modifiers.HasFlag(ModifierKeys.Shift))
        {
            e.Handled = true;
            await SendAsync();
        }
    }

    private async Task SendAsync()
    {
        var text = InputBox.Text.Trim();
        if (string.IsNullOrEmpty(text) || _isSending) return;

        _isSending = true;
        SendButton.IsEnabled = false;
        InputBox.Text = "";

        _history.Add(new ChatMessage { Role = ChatRole.User, Content = text });
        _bubbles.Add(new ChatBubbleViewModel(ChatRole.User, text));
        ScrollToEnd();

        // Placeholder bubble the streamed reply fills in token-by-token.
        var assistantBubble = new ChatBubbleViewModel(ChatRole.Assistant, "");
        _bubbles.Add(assistantBubble);

        try
        {
            var result = await RouterHandler.HandleAsync(
                _history,
                onStreamChunk: token => Dispatcher.Invoke(() =>
                {
                    assistantBubble.Text += token;
                    ScrollToEnd();
                }));

            // For non-streamed routes (local_response, gpt_query, clarify, etc.) the
            // bubble is still empty at this point — fill it with the final text.
            if (string.IsNullOrEmpty(assistantBubble.Text))
                assistantBubble.Text = result.Text;

            _history.Add(new ChatMessage { Role = ChatRole.Assistant, Content = assistantBubble.Text });
        }
        catch (Exception ex)
        {
            assistantBubble.Text = $"Something went wrong: {ex.Message}";
        }
        finally
        {
            _isSending = false;
            SendButton.IsEnabled = true;
            ScrollToEnd();
        }
    }

    private void ScrollToEnd() => Scroller.ScrollToBottom();
}
