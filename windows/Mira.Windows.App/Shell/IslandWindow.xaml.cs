using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Mira.Windows.Core.Account;
using Mira.Windows.Core.Chat;
using Mira.Windows.Core.Entitlements;
using Mira.Windows.Core.Vision;
using Button = System.Windows.Controls.Button;

namespace Mira.Windows.App.Shell;

/// <summary>Which content pane the expanded island is currently showing — mirrors the Mac island's tab set (<c>MiraIslandView.swift</c>'s 9 nav icons + Settings pinned far right).</summary>
public enum IslandTab { Home, Chat, Shelf, Camera, Agents, Labs, Skills, Learn, Crons, Settings }

/// <summary>
/// Windows' notch/island shell (see docs/windows/IMPLEMENTATION_PLAN.md Phase
/// 6) — a collapse/expand pill anchored top-center of the primary screen that
/// is now, as of this pass, the app's primary always-shown surface: it opens
/// unconditionally at launch regardless of sign-in state (previously a
/// separate <see cref="MainWindow"/> handled sign-in and only showed the
/// island once already signed in — the Mac app has no such split, its notch
/// is present for the whole session and its own tabs handle everything,
/// which is what this pass moves Windows toward).
///
/// Tabs mirror the Mac nav bar: Home, Chat, Shelf, Camera, Agents, Labs,
/// Skills, Learn, Crons, plus Settings pinned far right as a gear icon. Only
/// Home/Chat/Settings have real content — the other six render a calm
/// "not available yet" placeholder rather than pretending, the same
/// "recognize but can't do it" philosophy <see cref="RouterHandler"/> already
/// uses for unimplemented chat routes. Settings folds in what used to be
/// <see cref="MainWindow"/>'s entire signed-out/signed-in UI (sign-in form,
/// plan, autonomy toggle, sign out) — <see cref="MainWindow"/> itself still
/// exists and is still reachable from the tray as a fallback, just no longer
/// auto-shown or the primary way to sign in.
/// </summary>
public partial class IslandWindow : Window
{
    private const double SidePad = 24, BottomPad = 24;
    private const double CollapsedPillWidth = 200, CollapsedPillHeight = 40;
    // Wider, not taller, than the first pass -- matches the Mac panel's own
    // landscape proportions (700x252-420) rather than a tall, narrow popup.
    private const double ExpandedPillWidth = 700, ExpandedPillHeight = 460;
    private const int CollapseGraceMs = 600;

    private static readonly (IslandTab Tab, string Name)[] PlaceholderTabs =
    [
        (IslandTab.Shelf, "Shelf"), (IslandTab.Camera, "Camera"), (IslandTab.Agents, "Agents"),
        (IslandTab.Labs, "Labs"), (IslandTab.Skills, "Skills"), (IslandTab.Learn, "Learn"), (IslandTab.Crons, "Crons"),
    ];

    private readonly ObservableCollection<ChatBubbleViewModel> _bubbles = new();
    private readonly List<ChatMessage> _history = new();
    private bool _isExpanded;
    private bool _isSending;
    private bool _isSignUpMode;
    private IslandTab _activeTab = IslandTab.Home;
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
        Closed += (_, _) =>
        {
            _hotkey?.Dispose();
            AccountService.Shared.StateChanged -= OnAuthStateChanged;
            EntitlementService.Shared.PlanChanged -= OnPlanChanged;
        };

        ApplyCornerRadius(new CornerRadius(0, 0, 10, 10));

        AccountService.Shared.StateChanged += OnAuthStateChanged;
        EntitlementService.Shared.PlanChanged += OnPlanChanged;
        AutonomyCheckBox.IsChecked = AutonomySettings.ComputerUseEnabled;
        RenderForAuthState(AccountService.Shared.State);
        SelectTab(IslandTab.Home);
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

        if (expanded && _activeTab == IslandTab.Chat) InputBox.Focus();
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

    // ---- Tabs ----

    private void TabButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string tagStr } && Enum.TryParse<IslandTab>(tagStr, out var tab))
            SelectTab(tab);
    }

    private void SelectTab(IslandTab tab)
    {
        _activeTab = tab;

        HomePanel.Visibility = tab == IslandTab.Home ? Visibility.Visible : Visibility.Collapsed;
        ChatPanel.Visibility = tab == IslandTab.Chat ? Visibility.Visible : Visibility.Collapsed;
        SettingsScroller.Visibility = tab == IslandTab.Settings ? Visibility.Visible : Visibility.Collapsed;

        var placeholder = Array.Find(PlaceholderTabs, p => p.Tab == tab);
        if (placeholder.Name is not null)
        {
            PlaceholderPanel.Visibility = Visibility.Visible;
            PlaceholderText.Text = $"{placeholder.Name} isn't available on Windows yet — it's on the roadmap.";
        }
        else
        {
            PlaceholderPanel.Visibility = Visibility.Collapsed;
        }

        if (tab == IslandTab.Chat && _isExpanded) InputBox.Focus();
    }

    // ---- Home ----

    private void OpenVoiceButton_Click(object sender, RoutedEventArgs e) => new VoiceWindow().Show();

    // ---- Settings (folded in from the old MainWindow) ----

    private void OnAuthStateChanged(AuthState state) => Dispatcher.Invoke(() => RenderForAuthState(state));

    private void OnPlanChanged(Mira.Contracts.ProfileRow.ProfilePlan plan) => Dispatcher.Invoke(UpdatePlanAndHomeText);

    private void RenderForAuthState(AuthState state)
    {
        switch (state)
        {
            case AuthState.SignedIn:
                SettingsSignedOutPanel.Visibility = Visibility.Collapsed;
                SettingsSignedInPanel.Visibility = Visibility.Visible;
                var user = AccountService.Shared.CurrentUser;
                SignedInAsText.Text = $"Signed in as {user?.Email ?? user?.DisplayName ?? "(unknown)"}";
                UpdatePlanAndHomeText();
                break;

            case AuthState.SignedOut:
                SettingsSignedOutPanel.Visibility = Visibility.Visible;
                SettingsSignedInPanel.Visibility = Visibility.Collapsed;
                PrimaryActionButton.IsEnabled = true;
                HomeStatusText.Text = "Not signed in — open Settings (⚙) to sign in and get started.";
                break;

            case AuthState.Loading:
                PrimaryActionButton.IsEnabled = false;
                break;
        }
    }

    private void UpdatePlanAndHomeText()
    {
        var planName = EntitlementService.Shared.Plan.DisplayName();
        PlanText.Text = $"Plan: {planName}";
        var user = AccountService.Shared.CurrentUser;
        HomeStatusText.Text = $"Signed in as {user?.Email ?? user?.DisplayName ?? "(unknown)"} — Plan: {planName}";
    }

    private async void PrimaryActionButton_Click(object sender, RoutedEventArgs e)
    {
        ErrorText.Text = "";
        var email = EmailBox.Text.Trim();
        var password = PasswordBox.Password;

        if (string.IsNullOrEmpty(email) || string.IsNullOrEmpty(password))
        {
            ErrorText.Text = "Enter an email and password.";
            return;
        }

        try
        {
            if (_isSignUpMode)
            {
                var name = DisplayNameBox.Text.Trim();
                await AccountService.Shared.SignUpAsync(email, password, name);
                if (!AccountService.Shared.IsSignedIn)
                {
                    // SignUpAsync returned with no session and no exception = pending
                    // email confirmation — not an error, mirrors AccountService.swift.
                    ErrorText.Foreground = System.Windows.Media.Brushes.LightGreen;
                    ErrorText.Text = "Check your email to confirm your account, then sign in.";
                    _isSignUpMode = false;
                    ApplyModeToUi();
                }
            }
            else
            {
                await AccountService.Shared.SignInAsync(email, password);
            }
        }
        catch (Exception ex)
        {
            ErrorText.Foreground = System.Windows.Media.Brushes.OrangeRed;
            ErrorText.Text = ex.Message;
        }
    }

    private void ToggleModeButton_Click(object sender, RoutedEventArgs e)
    {
        _isSignUpMode = !_isSignUpMode;
        ApplyModeToUi();
    }

    private void ApplyModeToUi()
    {
        ModeLabel.Text = _isSignUpMode ? "Create account" : "Sign in";
        PrimaryActionButton.Content = _isSignUpMode ? "Create Account" : "Sign In";
        ToggleModeButton.Content = _isSignUpMode ? "Already have an account? Sign in" : "Need an account? Create one";
        DisplayNamePanel.Visibility = _isSignUpMode ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void RefreshPlanButton_Click(object sender, RoutedEventArgs e) => await EntitlementService.Shared.FetchAndApplyPlanAsync();

    private void SignOutButton_Click(object sender, RoutedEventArgs e) => AccountService.Shared.SignOut();

    private void AutonomyCheckBox_Changed(object sender, RoutedEventArgs e) => AutonomySettings.ComputerUseEnabled = AutonomyCheckBox.IsChecked == true;

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
