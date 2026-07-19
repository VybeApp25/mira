using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Mira.Windows.Core.Chat;

namespace Mira.Windows.App.Shell;

/// <summary>
/// Windows' notch/island shell (see docs/windows/IMPLEMENTATION_PLAN.md Phase
/// 6) — a collapse/expand pill anchored top-center of the primary screen,
/// with a Chat tab reusing the same <see cref="ChatBubbleViewModel"/>/
/// <see cref="RouterHandler"/> pipeline <see cref="ChatWindow"/> already uses.
///
/// The motion/shape details below are a deliberate second pass at visual
/// fidelity with the Mac original (Mira/Managers/AnimationController.swift,
/// Mira/Views/MiraIslandView.swift), after the first pass's plain size
/// animation + instant Visibility swap read as noticeably less polished:
/// - Corner radius animates via <see cref="CornerRadiusAnimation"/> (WPF has
///   no built-in one) instead of snapping, matching the Mac shape's
///   independently-animatable top/bottom radii.
/// - <see cref="BackEase"/> gives a slight overshoot-then-settle feel, the
///   closest built-in WPF stand-in for SwiftUI's
///   <c>.spring(response:dampingFraction:)</c> (0.40s/0.74 expanding,
///   0.30s/0.82 collapsing on macOS) without hand-building a full damped-
///   harmonic-oscillator easing function for a fairly subtle perceptual gain.
/// - Content crossfades (collapsed label vs. expanded panel) instead of an
///   instant Visibility toggle, mirroring the Mac panel's 140ms-in/100ms-out
///   staggered content fade.
/// - A real drop shadow, which needs the window itself padded beyond the
///   visible pill (see <see cref="SidePad"/>/<see cref="BottomPad"/>) since
///   WPF clips rendering to window bounds — no padding at the top, since the
///   pill sits flush with the screen edge exactly like the Mac original
///   fusing with the physical notch.
/// </summary>
public partial class IslandWindow : Window
{
    private const double SidePad = 24, BottomPad = 24;
    private const double CollapsedPillWidth = 200, CollapsedPillHeight = 40;
    private const double ExpandedPillWidth = 420, ExpandedPillHeight = 520;
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

        Width = CollapsedPillWidth + SidePad * 2;
        Height = CollapsedPillHeight + BottomPad;
        Top = 0; // flush with the screen's top edge -- no gap, matches the Mac pill fusing with the notch
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

        ApplyCornerRadius(new CornerRadius(0, 0, 10, 10));
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

        var targetWidth = (expanded ? ExpandedPillWidth : CollapsedPillWidth) + SidePad * 2;
        var targetHeight = (expanded ? ExpandedPillHeight : CollapsedPillHeight) + BottomPad;
        var targetRadius = new CornerRadius(0, 0, expanded ? 20 : 10, expanded ? 20 : 10);

        // BackEase's slight overshoot-then-settle is the closest built-in WPF
        // stand-in for SwiftUI's damped spring -- expanding uses a touch more
        // amplitude (lower damping on macOS, 0.74) than collapsing (0.82,
        // snappier/less bounce).
        var ease = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = expanded ? 0.25 : 0.12 };
        var duration = TimeSpan.FromMilliseconds(expanded ? 360 : 260);

        BeginAnimation(WidthProperty, new DoubleAnimation(Width, targetWidth, duration) { EasingFunction = ease });
        BeginAnimation(HeightProperty, new DoubleAnimation(Height, targetHeight, duration) { EasingFunction = ease });
        ApplyCornerRadius(targetRadius, duration, ease);
        CrossfadeContent(expanded);

        if (expanded) InputBox.Focus();
    }

    private void ApplyCornerRadius(CornerRadius target, TimeSpan? duration = null, BackEase? ease = null)
    {
        if (duration is null)
        {
            Shell.CornerRadius = target;
            ThinkingGlow.CornerRadius = target;
            return;
        }

        var anim = new CornerRadiusAnimation { From = Shell.CornerRadius, To = target, Duration = duration.Value, EasingFunction = ease };
        Shell.BeginAnimation(Border.CornerRadiusProperty, anim);
        ThinkingGlow.BeginAnimation(Border.CornerRadiusProperty, anim);
    }

    /// <summary>Fades the outgoing content out fast while the incoming content fades in slightly after — mirrors the Mac panel's own staggered 140ms-in/100ms-out content fade rather than an instant Visibility swap.</summary>
    private void CrossfadeContent(bool expanded)
    {
        UIElement outgoing = expanded ? CollapsedLabel : ExpandedContent;
        UIElement incoming = expanded ? ExpandedContent : CollapsedLabel;

        outgoing.BeginAnimation(OpacityProperty, null);
        incoming.BeginAnimation(OpacityProperty, null);

        incoming.Visibility = Visibility.Visible;
        incoming.Opacity = 0;

        var fadeOut = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(100));
        fadeOut.Completed += (_, _) => outgoing.Visibility = Visibility.Collapsed;
        outgoing.BeginAnimation(OpacityProperty, fadeOut);

        var fadeIn = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(160)) { BeginTime = TimeSpan.FromMilliseconds(60) };
        incoming.BeginAnimation(OpacityProperty, fadeIn);
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
