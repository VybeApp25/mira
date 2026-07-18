using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Mira.Windows.Core.Chat;

namespace Mira.Windows.App.Shell;

/// <summary>
/// Windows' first pass at the notch/island shell (see
/// docs/windows/IMPLEMENTATION_PLAN.md Phase 6) — deliberately just the core
/// shell for this milestone: a collapse/expand pill anchored top-center of the
/// primary screen (there's no physical notch on Windows to fuse with, so
/// top-center was chosen as the closest visual analog rather than porting the
/// Mac's per-notch geometry), a Chat tab reusing the same
/// <see cref="ChatBubbleViewModel"/>/<see cref="RouterHandler"/> pipeline
/// <see cref="ChatWindow"/> already uses, and a pulsing accent glow while a
/// reply is in flight (the Windows analog of the Mac pill's
/// listening/thinking/speaking states — narrower, since voice stays in its own
/// <see cref="VoiceWindow"/> for this pass rather than being folded into the
/// pill the way it is on macOS). Floating agent chips, the cursor-following
/// companion, and in-panel toasts are all separate macOS subsystems
/// deliberately deferred to a later pass — see the Phase 6 write-up for why.
/// </summary>
public partial class IslandWindow : Window
{
    private const double CollapsedWidth = 200, CollapsedHeight = 40;
    private const double ExpandedWidth = 420, ExpandedHeight = 520;
    private const int CollapseGraceMs = 600;

    private readonly ObservableCollection<ChatBubbleViewModel> _bubbles = new();
    private readonly List<ChatMessage> _history = new();
    private bool _isExpanded;
    private bool _isSending;
    private DispatcherTimer? _collapseTimer;
    private GlobalHotkey? _hotkey;

    public IslandWindow()
    {
        InitializeComponent();
        MessagesList.ItemsSource = _bubbles;

        Width = CollapsedWidth;
        Height = CollapsedHeight;
        Top = 8;
        SizeChanged += (_, _) => RecenterHorizontally();
        RecenterHorizontally();

        SourceInitialized += (_, _) =>
        {
            // Ctrl+Alt+T -- the Windows equivalent of the Mac app's "expand for
            // text" shortcut. Registered here (not the constructor) because
            // RegisterHotKey needs a real HWND, which only exists once the
            // window has actually been shown.
            _hotkey = new GlobalHotkey(this, id: 1, GlobalHotkey.ModControl | GlobalHotkey.ModAlt, GlobalHotkey.VkT);
            _hotkey.Pressed += () =>
            {
                Activate();
                SetExpanded(true);
            };
        };
        Closed += (_, _) => _hotkey?.Dispose();

        ApplyCornerRadius(expanded: false);
    }

    private void RecenterHorizontally() => Left = (SystemParameters.PrimaryScreenWidth - Width) / 2;

    // ---- Hover expand/collapse (mirrors the Mac island's hover-to-open, 600ms collapse grace) ----

    private void Shell_MouseEnter(object sender, System.Windows.Input.MouseEventArgs e)
    {
        _collapseTimer?.Stop();
        if (!_isExpanded) SetExpanded(true);
    }

    private void Shell_MouseLeave(object sender, System.Windows.Input.MouseEventArgs e)
    {
        _collapseTimer?.Stop();
        _collapseTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(CollapseGraceMs) };
        _collapseTimer.Tick += (_, _) =>
        {
            _collapseTimer!.Stop();
            if (!_isSending) SetExpanded(false); // don't collapse mid-reply, mirrors the Mac gate on pending confirmation/input
        };
        _collapseTimer.Start();
    }

    private void CollapseButton_Click(object sender, RoutedEventArgs e)
    {
        _collapseTimer?.Stop();
        SetExpanded(false);
    }

    private void SetExpanded(bool expanded)
    {
        if (_isExpanded == expanded) return;
        _isExpanded = expanded;

        var targetWidth = expanded ? ExpandedWidth : CollapsedWidth;
        var targetHeight = expanded ? ExpandedHeight : CollapsedHeight;
        var ease = new QuadraticEase { EasingMode = EasingMode.EaseOut };
        BeginAnimation(WidthProperty, new DoubleAnimation(Width, targetWidth, TimeSpan.FromMilliseconds(220)) { EasingFunction = ease });
        BeginAnimation(HeightProperty, new DoubleAnimation(Height, targetHeight, TimeSpan.FromMilliseconds(220)) { EasingFunction = ease });

        ApplyCornerRadius(expanded);
        CollapsedLabel.Visibility = expanded ? Visibility.Collapsed : Visibility.Visible;
        ExpandedContent.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;

        if (expanded) InputBox.Focus();
    }

    private void ApplyCornerRadius(bool expanded)
    {
        var radius = expanded ? 20 : 10;
        Shell.CornerRadius = new CornerRadius(0, 0, radius, radius);
        ThinkingGlow.CornerRadius = Shell.CornerRadius;
    }

    // ---- Chat (identical pipeline to ChatWindow — same RouterHandler call, same streaming) ----

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
        SetThinking(true);

        _history.Add(new ChatMessage { Role = ChatRole.User, Content = text });
        _bubbles.Add(new ChatBubbleViewModel(ChatRole.User, text));
        Scroller.ScrollToBottom();

        var assistantBubble = new ChatBubbleViewModel(ChatRole.Assistant, "");
        _bubbles.Add(assistantBubble);

        try
        {
            var result = await RouterHandler.HandleAsync(
                _history,
                onStreamChunk: token => Dispatcher.Invoke(() =>
                {
                    assistantBubble.Text += token;
                    Scroller.ScrollToBottom();
                }));

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
            SetThinking(false);
            Scroller.ScrollToBottom();
        }
    }

    private void SetThinking(bool thinking)
    {
        ThinkingGlow.BeginAnimation(OpacityProperty, null);
        if (!thinking)
        {
            ThinkingGlow.Opacity = 0;
            return;
        }

        var pulse = new DoubleAnimation(0.25, 0.9, TimeSpan.FromMilliseconds(900))
        {
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
        };
        ThinkingGlow.BeginAnimation(OpacityProperty, pulse);
    }
}
