using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using System.Windows.Interop;
using System.Diagnostics;
using System.IO;
using Mira.Windows.App.Camera;
using Mira.Windows.App.Home;
using Mira.Windows.Core.Account;
using Mira.Windows.Core.Agents;
using Mira.Windows.Core.Audio;
using Mira.Windows.Core.Browser;
using Mira.Windows.Core.Chat;
using Mira.Windows.Core.Clipboard;
using Mira.Windows.Core.Crons;
using Mira.Windows.Core.Learn;
using Mira.Windows.Core.Entitlements;
using Mira.Windows.Core.Shelf;
using Mira.Windows.Core.Skills;
using Mira.Windows.Core.Vision;
using Mira.Windows.Core.Voice;
using ClipboardWatcher = Mira.Windows.App.Clipboard.ClipboardWatcher;
using Button = System.Windows.Controls.Button;
using Color = System.Windows.Media.Color;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using Image = System.Windows.Controls.Image;
using Path = System.IO.Path;
using FontFamily = System.Windows.Media.FontFamily;
using ContextMenu = System.Windows.Controls.ContextMenu;
using MenuItem = System.Windows.Controls.MenuItem;
using Rectangle = System.Windows.Shapes.Rectangle;
using MemoryModel = Mira.Windows.Core.Memory.Memory;
using MemoryStore = Mira.Windows.Core.Memory.MemoryStore;
using MemoryConfidenceTier = Mira.Windows.Core.Memory.MemoryConfidenceTier;

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

    private static readonly (IslandTab Tab, string Name)[] PlaceholderTabs = [];

    /// <summary>Mirrors LabsTabView.swift's <c>SubTab</c> — Clipboard and Shelf are real, the rest render the same shared placeholder pattern as the top-level tabs.</summary>
    private enum LabsSubTab { Clipboard, Shelf, Shortcuts, Queue, Reminders }

    private static readonly (LabsSubTab Tab, string Name)[] LabsPlaceholderSubTabs =
    [
        (LabsSubTab.Shortcuts, "Shortcuts"), (LabsSubTab.Queue, "Queue"), (LabsSubTab.Reminders, "Reminders"),
    ];

    private static readonly string[] WeekdayInitials = ["S", "M", "T", "W", "T", "F", "S"];

    private readonly ObservableCollection<ChatBubbleViewModel> _bubbles = new();
    private readonly List<ChatMessage> _history = new();
    private bool _isExpanded;
    private bool _isSending;
    private bool _isSignUpMode;
    private IslandTab _activeTab = IslandTab.Home;
    private DispatcherTimer? _collapseTimer;
    private GlobalHotkey? _hotkey;
    private GlobalHotkey? _voiceHotkey;

    private bool _isSeekingNowPlaying;
    private WriteableBitmap? _cameraBitmap;
    private bool _cameraFrameDispatchPending;
    private readonly ClipboardWatcher _clipboardWatcher = new();
    private LabsSubTab _activeLabsSubTab = LabsSubTab.Clipboard;
    private string _clipboardSearchQuery = "";
    private string? _pendingSkillMarkdown;
    private Guid? _editingCronId;
    private CronScheduleKind _cronEditorKind = CronScheduleKind.Daily;

    private readonly Stopwatch _eyesClock = Stopwatch.StartNew();
    private DispatcherTimer? _eyesTimer;

    private bool _voiceSessionActive;
    private ChatBubbleViewModel? _voiceAssistantBubble;

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
                AudioCueService.Shared.PlayTextOpen(); // mirrors .miraActivateText's exact cue
            };

            // Ctrl+Alt+V -- the Windows equivalent of the Mac app's Control+Option+V
            // voice shortcut. Calls StartVoiceSessionAsync (not EnterVoiceModeAsync):
            // Mac's own voice shortcut stays in the closed notch too ("PTT — stays in
            // the closed notch pill"), matching wake word's exact non-expanding behavior.
            _voiceHotkey = new GlobalHotkey(this, id: 2, GlobalHotkey.ModControl | GlobalHotkey.ModAlt, GlobalHotkey.VkV);
            _voiceHotkey.Pressed += () => _ = StartVoiceSessionAsync();

            // Also needs a real HWND, same reason as the hotkey above.
            _clipboardWatcher.Start(this);

            // The OS forgets display affinity every time a new HWND is created,
            // so this re-applies the persisted preference each launch rather
            // than trusting any prior window's state.
            CaptureAffinity.Apply(this, AppearanceSettings.ShowInScreenCaptures);
        };
        Closed += (_, _) =>
        {
            _hotkey?.Dispose();
            _voiceHotkey?.Dispose();
            _clipboardWatcher.Stop();
            AccountService.Shared.StateChanged -= OnAuthStateChanged;
            EntitlementService.Shared.PlanChanged -= OnPlanChanged;
            NowPlayingService.Shared.Changed -= OnNowPlayingChanged;
            CameraPreviewService.Shared.FrameArrived -= OnCameraFrame;
            CameraPreviewService.Shared.StartFailed -= OnCameraStartFailed;
            CameraPreviewService.Shared.Stop();
            ClipboardHistoryStore.Shared.Changed -= OnClipboardHistoryChanged;
            AgentJobStore.Shared.Changed -= OnAgentJobsChanged;
            SkillStore.Shared.Changed -= OnSkillsChanged;
            FileShelfStore.Shared.Changed -= OnShelfChanged;
            CronStore.Shared.Changed -= OnCronsChanged;
            CronScheduler.Shared.Stop();
            LessonStore.Shared.Changed -= OnLearnChanged;
            LessonProgressStore.Shared.Changed -= OnLearnChanged;
            LessonRunner.Shared.Changed -= OnLearnChanged;
            LessonRunner.Shared.Stop();
            MemoryStore.Shared.Changed -= OnMemoryChanged;
            WakeWordService.Shared.Detected -= OnWakeWordDetected;
            WakeWordService.Shared.Pause();
            RealtimeVoiceService.Shared.StateChanged -= OnVoiceStateChanged;
            RealtimeVoiceService.Shared.AssistantTranscriptDelta -= OnVoiceTranscriptDelta;
            RealtimeVoiceService.Shared.ErrorOccurred -= OnVoiceError;
            RealtimeVoiceService.Shared.Warning -= OnVoiceWarning;
            if (_voiceSessionActive) _ = RealtimeVoiceService.Shared.DisconnectAsync();
            _eyesTimer?.Stop();
        };

        ApplyCornerRadius(new CornerRadius(0, 0, 10, 10));

        AccountService.Shared.StateChanged += OnAuthStateChanged;
        EntitlementService.Shared.PlanChanged += OnPlanChanged;
        AutonomyCheckBox.IsChecked = AutonomySettings.ComputerUseEnabled;
        ConfirmRiskyCheckBox.IsChecked = AutonomySettings.ConfirmRiskyActions;
        CatModeCheckBox.IsChecked = PersonalitySettings.CatModeEnabled;
        ShowInCaptureCheckBox.IsChecked = AppearanceSettings.ShowInScreenCaptures;
        SoundEffectsCheckBox.IsChecked = !AudioCueSettings.IsMuted;
        PopulateBrowserPreferenceCombo();
        PopulateInputDeviceCombo();
        PopulateOutputDeviceCombo();
        WakeWordDeviceText.Text = AudioDevices.DefaultWakeWordInputDeviceName() ?? "Could not detect a default microphone.";
        AlwaysOnCheckBox.IsChecked = VoiceAlwaysOnSettings.IsEnabled;
        RenderForAuthState(AccountService.Shared.State);

        // Home tab is the default landing tab, matching NotchHomeIdleView's
        // .onAppear { np.start() } -- started unconditionally here rather
        // than gated to first-tab-selection since Home is always the first
        // thing shown.
        NowPlayingBridge.Current = NowPlayingService.Shared;
        NowPlayingService.Shared.Changed += OnNowPlayingChanged;
        _ = NowPlayingService.Shared.StartAsync();
        RenderNowPlaying();
        BuildCalendarStrip();

        CameraPreviewService.Shared.FrameArrived += OnCameraFrame;
        CameraPreviewService.Shared.StartFailed += OnCameraStartFailed;

        ClipboardHistoryStore.Shared.Changed += OnClipboardHistoryChanged;
        RenderClipboardList();

        AgentJobStore.Shared.Changed += OnAgentJobsChanged;
        RenderAgentJobList();

        SkillStore.Shared.Changed += OnSkillsChanged;

        FileShelfStore.Shared.Changed += OnShelfChanged;

        CronStore.Shared.Changed += OnCronsChanged;
        CronScheduler.Shared.Start();
        PopulateCronCombos();

        // Eyes animate continuously regardless of collapse state -- mirrors
        // SharedStatusView's "always-mounted, time-driven" design so nothing
        // resets when the pill expands/collapses.
        _eyesTimer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(33) };
        _eyesTimer.Tick += (_, _) => UpdateEyes();
        _eyesTimer.Start();

        MemoryStore.Shared.Changed += OnMemoryChanged;
        RenderMemoryList();

        LessonStore.Shared.Changed += OnLearnChanged;
        LessonProgressStore.Shared.Changed += OnLearnChanged;
        LessonRunner.Shared.Changed += OnLearnChanged;

        // Mirrors NotchManager.swift's wakeWord.start() at launch -- wake word
        // self-gates on WakeWordSettings.IsEnabled, so this is a no-op when
        // the user has the toggle off.
        WakeWordBridge.Current = WakeWordService.Shared;
        WakeWordCheckBox.IsChecked = WakeWordSettings.IsEnabled;
        WakeWordService.Shared.Detected += OnWakeWordDetected;
        WakeWordService.Shared.Start();

        // Voice lives entirely inside this window's Chat tab -- there is no
        // separate voice window, mirroring IslandChatView.swift's realtime
        // wiring being part of the notch itself, not a standalone surface.
        RealtimeVoiceService.Shared.StateChanged += OnVoiceStateChanged;
        RealtimeVoiceService.Shared.AssistantTranscriptDelta += OnVoiceTranscriptDelta;
        RealtimeVoiceService.Shared.ErrorOccurred += OnVoiceError;
        RealtimeVoiceService.Shared.Warning += OnVoiceWarning;

        // Mirrors the Swift original's connectAlwaysOn() being called "on app
        // launch" when already enabled -- no wake word or button click needed.
        if (VoiceAlwaysOnSettings.IsEnabled) StartAlwaysOnListening();

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

        // Mirrors NotchManager.swift's expandForShortcut() pausing the wake
        // word while expanded (so it doesn't also react to the user's own
        // typed/spoken input) and performCollapseIfIdle's restart once
        // collapsed back to idle.
        if (expanded) WakeWordService.Shared.Pause();
        else WakeWordService.Shared.Start();

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
        UIElement outgoing = expanded ? CollapsedIdleView : ExpandedContent;
        UIElement incoming = expanded ? ExpandedContent : CollapsedIdleView;

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

    // ---- Eyes (collapsed idle/listening/speaking states) ----

    private const double EyeBlinkIntervalSeconds = 3.7;
    private const double EyeBlinkDurationSeconds = 0.09;

    private static readonly SolidColorBrush IrisTealBrush = new(Color.FromArgb(0xEB, 0x0D, 0xCC, 0xC0));
    private static readonly SolidColorBrush IrisBlueBrush = new(Color.FromArgb(0xEB, 0x25, 0x63, 0xEB));
    private static readonly SolidColorBrush VoiceBarBlueBrush = new(Color.FromArgb(0xE0, 0x25, 0x63, 0xEB));
    private static readonly SolidColorBrush VoiceBarTealBrush = new(Color.FromArgb(0xE0, 0x0D, 0xCC, 0xC0));

    // Mirrors SharedStatusView.swift's listenSpeeds/listenOffsets (first 5 slots) and
    // reedSpeeds/reedOffsets (all 7) -- per-bar sine speed/phase so the waveform looks
    // alive rather than uniformly pulsing.
    private static readonly double[] VoiceBarSpeeds = [0.30, 0.38, 0.28, 0.42, 0.33, 0.38, 0.29];
    private static readonly double[] VoiceBarOffsets = [0.00, 0.22, 0.44, 0.11, 0.33, 0.44, 0.27];

    private Rectangle[]? _voiceBars;

    /// <summary>
    /// Mirrors SharedStatusView.swift's <c>notchEyes</c>/<c>singleEye</c>: both eyes
    /// share one blink cadence but drift their gaze on offset phases (0.0 / 0.4) so
    /// they don't move in perfect lockstep. Also drives the collapsed pill's
    /// Idle/Listening/Speaking visuals: iris tints blue and 5 waveform bars appear
    /// while <see cref="RealtimeVoiceService"/> is Listening, iris stays its default
    /// teal and 7 bars appear while Speaking -- mirroring exactly how Mac renders
    /// <c>notchEyes(t:irisColor:)</c> alongside its listening/reed waveforms.
    /// </summary>
    private void UpdateEyes()
    {
        var t = _eyesClock.Elapsed.TotalSeconds;
        var state = RealtimeVoiceService.Shared.State;
        var irisBrush = state == VoiceSessionState.Listening ? IrisBlueBrush : IrisTealBrush;

        UpdateSingleEye(t, gazePhase: 0.0, EyeLeftSclera, EyeLeftIris, EyeLeftPupil, EyeLeftIrisTransform, EyeLeftPupilTransform, irisBrush);
        UpdateSingleEye(t, gazePhase: 0.4, EyeRightSclera, EyeRightIris, EyeRightPupil, EyeRightIrisTransform, EyeRightPupilTransform, irisBrush);
        UpdateVoiceBars(t, state);
    }

    private static void UpdateSingleEye(
        double t, double gazePhase, Rectangle sclera, Ellipse iris, Ellipse pupil,
        TranslateTransform irisTransform, TranslateTransform pupilTransform, SolidColorBrush irisBrush)
    {
        var gazeX = Math.Sin((t + gazePhase) / 2.2 * Math.PI) * 1.6;
        var phase = t % EyeBlinkIntervalSeconds;
        var closed = phase < EyeBlinkDurationSeconds;

        sclera.Height = closed ? 2 : 7;
        iris.Visibility = closed ? Visibility.Collapsed : Visibility.Visible;
        pupil.Visibility = closed ? Visibility.Collapsed : Visibility.Visible;
        iris.Fill = irisBrush;
        irisTransform.X = gazeX;
        pupilTransform.X = gazeX;
    }

    private void UpdateVoiceBars(double t, VoiceSessionState state)
    {
        var showBars = state is VoiceSessionState.Listening or VoiceSessionState.Speaking;
        CollapsedVoiceBars.Visibility = showBars ? Visibility.Visible : Visibility.Collapsed;
        if (!showBars) return;

        _voiceBars ??= [VoiceBar0, VoiceBar1, VoiceBar2, VoiceBar3, VoiceBar4, VoiceBar5, VoiceBar6];
        var visibleCount = state == VoiceSessionState.Listening ? 5 : 7;
        var brush = state == VoiceSessionState.Listening ? VoiceBarBlueBrush : VoiceBarTealBrush;
        const double minH = 3, maxH = 12;

        for (var i = 0; i < _voiceBars.Length; i++)
        {
            var bar = _voiceBars[i];
            if (i >= visibleCount)
            {
                bar.Visibility = Visibility.Collapsed;
                continue;
            }
            bar.Visibility = Visibility.Visible;
            bar.Fill = brush;
            var amp = (Math.Sin((t + VoiceBarOffsets[i]) / VoiceBarSpeeds[i] * Math.PI * 2) + 1) / 2;
            bar.Height = minH + amp * (maxH - minH);
        }
    }

    // ---- Tabs ----

    private void TabButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string tagStr } && Enum.TryParse<IslandTab>(tagStr, out var tab))
            SelectTab(tab);
    }

    private void SelectTab(IslandTab tab)
    {
        var previousTab = _activeTab;
        _activeTab = tab;

        HomePanel.Visibility = tab == IslandTab.Home ? Visibility.Visible : Visibility.Collapsed;
        ChatPanel.Visibility = tab == IslandTab.Chat ? Visibility.Visible : Visibility.Collapsed;
        ShelfPanel.Visibility = tab == IslandTab.Shelf ? Visibility.Visible : Visibility.Collapsed;
        CameraPanel.Visibility = tab == IslandTab.Camera ? Visibility.Visible : Visibility.Collapsed;
        LabsPanel.Visibility = tab == IslandTab.Labs ? Visibility.Visible : Visibility.Collapsed;
        AgentsPanel.Visibility = tab == IslandTab.Agents ? Visibility.Visible : Visibility.Collapsed;
        SkillsPanel.Visibility = tab == IslandTab.Skills ? Visibility.Visible : Visibility.Collapsed;
        CronsPanel.Visibility = tab == IslandTab.Crons ? Visibility.Visible : Visibility.Collapsed;
        LearnPanel.Visibility = tab == IslandTab.Learn ? Visibility.Visible : Visibility.Collapsed;
        SettingsScroller.Visibility = tab == IslandTab.Settings ? Visibility.Visible : Visibility.Collapsed;

        if (tab == IslandTab.Skills) RenderSkillsList();
        if (tab == IslandTab.Shelf) RenderShelfList();
        if (tab == IslandTab.Crons) RenderCronList();
        if (tab == IslandTab.Learn) RenderLearnTab();

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

        // Only capture while the tab is actually visible -- mirrors
        // NotchCameraTabView's .onAppear/.onDisappear start/stop lifecycle,
        // so the camera light isn't on any longer than the user can see the preview.
        if (tab == IslandTab.Camera && previousTab != IslandTab.Camera)
        {
            CameraStatusText.Text = "Starting camera…";
            CameraPlaceholder.Visibility = Visibility.Visible;
            _ = CameraPreviewService.Shared.StartAsync();
        }
        else if (tab != IslandTab.Camera && previousTab == IslandTab.Camera)
        {
            CameraPreviewService.Shared.Stop();
            CameraImage.Source = null;
            _cameraBitmap = null;
        }

        // Mirrors IslandChatView.swift's .onAppear/.onDisappear cues -- entering/leaving
        // the Chat tab specifically, not any other tab switch.
        if (tab == IslandTab.Chat && previousTab != IslandTab.Chat) AudioCueService.Shared.Play(MiraSound.Enter);
        else if (tab != IslandTab.Chat && previousTab == IslandTab.Chat) AudioCueService.Shared.PlayTextClose();
    }

    // ---- Home: Now Playing media panel ----

    private void OpenVoiceButton_Click(object sender, RoutedEventArgs e) => _ = EnterVoiceModeAsync();

    // Mirrors NotchManager.swift's .miraActivateVoice handler exactly: starts the
    // session without expanding or switching tabs -- fires from a WinRT callback
    // thread, so marshal to the UI thread first.
    private void OnWakeWordDetected(object? sender, EventArgs e) => Dispatcher.Invoke(() => _ = StartVoiceSessionAsync());

    private void OnNowPlayingChanged() => Dispatcher.Invoke(RenderNowPlaying);

    private void RenderNowPlaying()
    {
        var np = NowPlayingService.Shared;

        NowPlayingContent.Visibility = np.HasContent ? Visibility.Visible : Visibility.Collapsed;
        NowPlayingNothingText.Visibility = np.HasContent ? Visibility.Collapsed : Visibility.Visible;
        if (!np.HasContent)
        {
            AlbumArt.Source = null;
            AlbumArtGlow.Source = null;
            NoArtIcon.Visibility = Visibility.Visible;
            return;
        }

        TrackTitleText.Text = np.Title;
        TrackArtistText.Text = np.Artist;
        PlayPauseButton.Content = np.IsPlaying ? "⏸" : "▶";
        ShuffleButton.Opacity = np.IsShuffleActive ? 1.0 : 0.55;
        RepeatButton.Opacity = np.IsRepeatActive ? 1.0 : 0.55;

        if (np.ThumbnailBgra is not null && np.ThumbnailWidth > 0 && np.ThumbnailHeight > 0)
        {
            var bmp = CreateBitmapSource(np.ThumbnailBgra, np.ThumbnailWidth, np.ThumbnailHeight);
            AlbumArt.Source = bmp;
            AlbumArtGlow.Source = bmp;
            NoArtIcon.Visibility = Visibility.Collapsed;
        }
        else
        {
            AlbumArt.Source = null;
            AlbumArtGlow.Source = null;
            NoArtIcon.Visibility = Visibility.Visible;
        }

        if (!_isSeekingNowPlaying)
        {
            var duration = np.Duration.TotalSeconds > 0 ? np.Duration.TotalSeconds : 1;
            var progress = Math.Clamp(np.Position.TotalSeconds / duration, 0, 1);
            SeekFill.Width = SeekTrack.ActualWidth * progress;
            PositionText.Text = FormatTime(np.Position);
            DurationText.Text = FormatTime(np.Duration);
        }
    }

    private static string FormatTime(TimeSpan t) => $"{(int)t.TotalMinutes}:{t.Seconds:D2}";

    private async void ShuffleButton_Click(object sender, RoutedEventArgs e) => await NowPlayingService.Shared.ToggleShuffleAsync();
    private async void PreviousButton_Click(object sender, RoutedEventArgs e) => await NowPlayingService.Shared.PreviousTrackAsync();
    private async void PlayPauseButton_Click(object sender, RoutedEventArgs e) => await NowPlayingService.Shared.TogglePlayPauseAsync();
    private async void NextButton_Click(object sender, RoutedEventArgs e) => await NowPlayingService.Shared.NextTrackAsync();
    private async void RepeatButton_Click(object sender, RoutedEventArgs e) => await NowPlayingService.Shared.ToggleRepeatAsync();

    private void SeekTrack_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _isSeekingNowPlaying = true;
        UpdateSeekPreview(e.GetPosition(SeekTrack).X);
        ((UIElement)sender).CaptureMouse();
    }

    private void SeekTrack_MouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (_isSeekingNowPlaying) UpdateSeekPreview(e.GetPosition(SeekTrack).X);
    }

    private async void SeekTrack_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (!_isSeekingNowPlaying) return;
        ((UIElement)sender).ReleaseMouseCapture();
        var ratio = Math.Clamp(e.GetPosition(SeekTrack).X / Math.Max(SeekTrack.ActualWidth, 1), 0, 1);
        _isSeekingNowPlaying = false;
        await NowPlayingService.Shared.SeekAsync(TimeSpan.FromSeconds(ratio * NowPlayingService.Shared.Duration.TotalSeconds));
    }

    private void UpdateSeekPreview(double x)
    {
        var ratio = Math.Clamp(x / Math.Max(SeekTrack.ActualWidth, 1), 0, 1);
        SeekFill.Width = SeekTrack.ActualWidth * ratio;
        PositionText.Text = FormatTime(TimeSpan.FromSeconds(ratio * NowPlayingService.Shared.Duration.TotalSeconds));
    }

    // ---- Home: calendar panel (visual shell only -- no Windows calendar account integration yet) ----

    private void BuildCalendarStrip()
    {
        var today = DateTime.Today;
        CalendarMonthYearText.Text = today.ToString("MMMM yyyy");
        CalendarDateStrip.Children.Clear();

        for (var offset = -3; offset <= 3; offset++)
        {
            var day = today.AddDays(offset);
            var isToday = offset == 0;

            var dayNumber = new Border
            {
                Width = 20,
                Height = 20,
                CornerRadius = new CornerRadius(10),
                Background = isToday ? new SolidColorBrush(Color.FromRgb(0x25, 0x63, 0xEB)) : System.Windows.Media.Brushes.Transparent,
                Child = new TextBlock
                {
                    Text = day.Day.ToString(),
                    FontSize = 11,
                    FontWeight = isToday ? FontWeights.Bold : FontWeights.Medium,
                    Foreground = System.Windows.Media.Brushes.White,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            };

            var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
            stack.Children.Add(new TextBlock
            {
                Text = WeekdayInitials[(int)day.DayOfWeek],
                FontSize = 8,
                Foreground = new SolidColorBrush(Color.FromArgb(0x59, 0xFF, 0xFF, 0xFF)),
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 0, 0, 2),
            });
            stack.Children.Add(dayNumber);

            var button = new Button { Style = (Style)FindResource("CalendarDayButtonStyle"), Content = stack };
            CalendarDateStrip.Children.Add(button);
        }
    }

    // ---- Camera ----

    private void OnCameraFrame(byte[] bgra, int width, int height)
    {
        if (_cameraFrameDispatchPending) return; // drop frames the UI thread can't keep up with rather than backing up the WinRT capture thread
        _cameraFrameDispatchPending = true;
        Dispatcher.BeginInvoke(() =>
        {
            _cameraFrameDispatchPending = false;
            if (_activeTab != IslandTab.Camera) return; // stopped/switched away while this frame was in flight

            if (_cameraBitmap is null || _cameraBitmap.PixelWidth != width || _cameraBitmap.PixelHeight != height)
            {
                _cameraBitmap = new WriteableBitmap(width, height, 96, 96, PixelFormats.Bgra32, null);
                CameraImage.Source = _cameraBitmap;
            }
            _cameraBitmap.WritePixels(new Int32Rect(0, 0, width, height), bgra, width * 4, 0);
            CameraPlaceholder.Visibility = Visibility.Collapsed;
        });
    }

    private void OnCameraStartFailed(string message) => Dispatcher.Invoke(() =>
    {
        CameraPlaceholder.Visibility = Visibility.Visible;
        CameraStatusText.Text = message;
    });

    private static BitmapSource CreateBitmapSource(byte[] bgra, int width, int height)
    {
        var bmp = new WriteableBitmap(width, height, 96, 96, PixelFormats.Bgra32, null);
        bmp.WritePixels(new Int32Rect(0, 0, width, height), bgra, width * 4, 0);
        bmp.Freeze();
        return bmp;
    }

    // ---- Shelf ----

    private void OnShelfChanged() => Dispatcher.Invoke(RenderShelfList);

    private void ShelfOpenFolderButton_Click(object sender, RoutedEventArgs e) => FileShelfStore.Shared.OpenShelfFolder();

    private void ShelfClearButton_Click(object sender, RoutedEventArgs e) => FileShelfStore.Shared.Clear();

    private void ShelfDropZone_DragEnter(object sender, System.Windows.DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(System.Windows.DataFormats.FileDrop) ? System.Windows.DragDropEffects.Copy : System.Windows.DragDropEffects.None;
        ShelfDropZoneText.Opacity = 1.0;
        e.Handled = true;
    }

    private void ShelfDropZone_DragLeave(object sender, System.Windows.DragEventArgs e) => ShelfDropZoneText.Opacity = 0.66;

    private void ShelfDropZone_Drop(object sender, System.Windows.DragEventArgs e)
    {
        ShelfDropZoneText.Opacity = 0.66;
        if (e.Data.GetData(System.Windows.DataFormats.FileDrop) is string[] paths)
            FileShelfStore.Shared.Add(paths.Where(File.Exists));
    }

    private void RenderShelfList()
    {
        var store = FileShelfStore.Shared;
        ShelfDropZoneText.Text = store.AtLimit ? "Shelf full" : "Drop files here";
        ShelfLimitText.Text = store.Limit == int.MaxValue
            ? $"{store.Items.Count} item(s) · Unlimited"
            : $"{store.Items.Count}/{store.Limit} · Ultra for unlimited";

        ShelfList.Children.Clear();
        var items = store.Items;
        if (items.Count == 0)
        {
            ShelfList.Children.Add(new TextBlock
            {
                Text = "Shelf is empty — drag files onto the drop zone above to hold them here temporarily.",
                Foreground = new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF)),
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
                Margin = new Thickness(0, 24, 0, 0),
            });
            return;
        }

        foreach (var path in items) ShelfList.Children.Add(BuildShelfRow(path));
    }

    private UIElement BuildShelfRow(string path)
    {
        var row = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0x0D, 0xFF, 0xFF, 0xFF)),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10, 7, 6, 7),
            Margin = new Thickness(0, 0, 0, 6),
        };

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var iconImage = GetFileIcon(path);
        UIElement iconElement = iconImage is not null
            ? new Image { Source = iconImage, Width = 18, Height = 18, Margin = new Thickness(0, 0, 8, 0) }
            : new TextBlock { Text = "📄", FontSize = 14, Margin = new Thickness(0, 0, 8, 0) };
        iconElement.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        Grid.SetColumn(iconElement, 0);

        var nameText = new TextBlock
        {
            Text = Path.GetFileName(path),
            Foreground = System.Windows.Media.Brushes.White,
            FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        Grid.SetColumn(nameText, 1);

        var deleteButton = new Button
        {
            Content = "✕",
            FontSize = 11,
            Width = 22,
            Height = 22,
            Background = System.Windows.Media.Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Foreground = new SolidColorBrush(Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF)),
            Cursor = System.Windows.Input.Cursors.Hand,
            ToolTip = "Remove",
        };
        deleteButton.Click += (_, e) => { e.Handled = true; FileShelfStore.Shared.Remove(path); };
        Grid.SetColumn(deleteButton, 2);

        grid.Children.Add(iconElement);
        grid.Children.Add(nameText);
        grid.Children.Add(deleteButton);
        row.Child = grid;
        return row;
    }

    /// <summary>Real per-file shell icon (Windows' equivalent of Mac's <c>NSWorkspace.icon(forFile:)</c>) with a plain emoji fallback if extraction fails.</summary>
    private static BitmapSource? GetFileIcon(string path)
    {
        try
        {
            using var icon = System.Drawing.Icon.ExtractAssociatedIcon(path);
            if (icon is null) return null;
            var bmp = Imaging.CreateBitmapSourceFromHIcon(icon.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            bmp.Freeze();
            return bmp;
        }
        catch
        {
            return null;
        }
    }

    // ---- Labs / Clipboard ----

    private void LabsSubTabButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string tagStr } && Enum.TryParse<LabsSubTab>(tagStr, out var tab))
            SelectLabsSubTab(tab);
    }

    private void SelectLabsSubTab(LabsSubTab tab)
    {
        _activeLabsSubTab = tab;
        LabsClipboardPanel.Visibility = tab == LabsSubTab.Clipboard ? Visibility.Visible : Visibility.Collapsed;
        LabsShelfRedirectPanel.Visibility = tab == LabsSubTab.Shelf ? Visibility.Visible : Visibility.Collapsed;

        var placeholder = Array.Find(LabsPlaceholderSubTabs, p => p.Tab == tab);
        if (placeholder.Name is not null)
        {
            LabsPlaceholderPanel.Visibility = Visibility.Visible;
            LabsPlaceholderText.Text = $"{placeholder.Name} isn't available on Windows yet — it's on the roadmap.";
        }
        else
        {
            LabsPlaceholderPanel.Visibility = Visibility.Collapsed;
        }
    }

    private void LabsShelfOpenButton_Click(object sender, RoutedEventArgs e) => SelectTab(IslandTab.Shelf);

    private void ClipboardSearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        _clipboardSearchQuery = ClipboardSearchBox.Text;
        RenderClipboardList();
    }

    private void OnClipboardHistoryChanged() => Dispatcher.Invoke(RenderClipboardList);

    private void RenderClipboardList()
    {
        ClipboardList.Children.Clear();
        IEnumerable<ClipboardItem> items = ClipboardHistoryStore.Shared.History;

        if (!string.IsNullOrWhiteSpace(_clipboardSearchQuery))
        {
            var q = _clipboardSearchQuery.Trim();
            items = items.Where(i =>
                (i.Text ?? "").Contains(q, StringComparison.OrdinalIgnoreCase) ||
                i.DisplayTitle.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                (i.SourceApp ?? "").Contains(q, StringComparison.OrdinalIgnoreCase));
        }

        var list = items.Take(200).ToList(); // cap rendered rows -- this is a live UI list, not a paged data grid
        if (list.Count == 0)
        {
            ClipboardList.Children.Add(new TextBlock
            {
                Text = "No clipboard history yet — copy something to see it here.",
                Foreground = new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF)),
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
                Margin = new Thickness(0, 24, 0, 0),
            });
            return;
        }

        foreach (var item in list) ClipboardList.Children.Add(BuildClipboardRow(item));
    }

    private UIElement BuildClipboardRow(ClipboardItem item)
    {
        var row = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0x0D, 0xFF, 0xFF, 0xFF)),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10, 7, 6, 7),
            Margin = new Thickness(0, 0, 0, 6),
            Cursor = System.Windows.Input.Cursors.Hand,
        };

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var icon = new TextBlock { Text = item.Icon, FontSize = 14, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        Grid.SetColumn(icon, 0);

        var textStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        textStack.Children.Add(new TextBlock
        {
            Text = item.DisplayTitle,
            Foreground = System.Windows.Media.Brushes.White,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        textStack.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(item.SourceApp) ? FormatRelativeTime(item.CopiedAt) : $"{item.SourceApp} · {FormatRelativeTime(item.CopiedAt)}",
            Foreground = new SolidColorBrush(Color.FromArgb(0x59, 0xFF, 0xFF, 0xFF)),
            FontSize = 9,
            Margin = new Thickness(0, 2, 0, 0),
        });
        Grid.SetColumn(textStack, 1);

        var pinButton = new Button
        {
            Content = "📌",
            FontSize = 12,
            Width = 22,
            Height = 22,
            Background = System.Windows.Media.Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Opacity = item.IsPinned ? 1.0 : 0.35,
            Cursor = System.Windows.Input.Cursors.Hand,
            ToolTip = item.IsPinned ? "Unpin" : "Pin",
        };
        pinButton.Click += (_, e) => { e.Handled = true; ClipboardHistoryStore.Shared.TogglePin(item.Id); };
        Grid.SetColumn(pinButton, 2);

        var deleteButton = new Button
        {
            Content = "✕",
            FontSize = 11,
            Width = 22,
            Height = 22,
            Background = System.Windows.Media.Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Foreground = new SolidColorBrush(Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF)),
            Cursor = System.Windows.Input.Cursors.Hand,
            ToolTip = "Delete",
        };
        deleteButton.Click += (_, e) => { e.Handled = true; ClipboardHistoryStore.Shared.Delete(item.Id); };
        Grid.SetColumn(deleteButton, 3);

        grid.Children.Add(icon);
        grid.Children.Add(textStack);
        grid.Children.Add(pinButton);
        grid.Children.Add(deleteButton);
        row.Child = grid;

        row.MouseLeftButtonUp += (_, _) => CopyItemToClipboard(item);
        return row;
    }

    private static void CopyItemToClipboard(ClipboardItem item)
    {
        try
        {
            switch (item.Kind)
            {
                case ClipboardItemKind.Text or ClipboardItemKind.Url or ClipboardItemKind.Code or ClipboardItemKind.Color:
                    if (item.Text is not null) System.Windows.Clipboard.SetText(item.Text);
                    break;

                case ClipboardItemKind.Image:
                    if (item.ImagePng is not null)
                    {
                        using var ms = new System.IO.MemoryStream(item.ImagePng);
                        var decoder = new PngBitmapDecoder(ms, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                        System.Windows.Clipboard.SetImage(decoder.Frames[0]);
                    }
                    break;

                case ClipboardItemKind.File:
                    if (item.FilePaths is not null)
                    {
                        var collection = new System.Collections.Specialized.StringCollection();
                        collection.AddRange(item.FilePaths.ToArray());
                        System.Windows.Clipboard.SetFileDropList(collection);
                    }
                    break;
            }
        }
        catch
        {
            // The clipboard can be transiently locked by another process -- a failed
            // copy-back shouldn't be a crash, just a no-op the user can retry.
        }
    }

    private static string FormatRelativeTime(DateTimeOffset time)
    {
        var span = DateTimeOffset.UtcNow - time;
        if (span.TotalMinutes < 1) return "just now";
        if (span.TotalMinutes < 60) return $"{(int)span.TotalMinutes}m ago";
        if (span.TotalHours < 24) return $"{(int)span.TotalHours}h ago";
        return $"{(int)span.TotalDays}d ago";
    }

    // ---- Agents ----

    private void AgentPromptBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        var text = AgentPromptBox.Text;
        if (string.IsNullOrWhiteSpace(text))
        {
            AgentTypeBadge.Visibility = Visibility.Collapsed;
            return;
        }

        AgentTypeBadge.Visibility = Visibility.Visible;
        AgentTypeBadgeText.Text = AgentJob.Detect(text) switch
        {
            AgentJobType.DeepResearch => "🔎 Research",
            AgentJobType.ContentGeneration => "📝 Content",
            _ => "🤖 Task",
        };
    }

    private void AgentPromptBox_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            e.Handled = true;
            SubmitAgentJob();
        }
    }

    private void AgentSubmitButton_Click(object sender, RoutedEventArgs e) => SubmitAgentJob();

    private void SubmitAgentJob()
    {
        var prompt = AgentPromptBox.Text.Trim();
        if (string.IsNullOrEmpty(prompt)) return;

        var (job, error) = AgentJobStore.Shared.SubmitJob(prompt);
        if (error is not null)
        {
            AgentTypeBadge.Visibility = Visibility.Visible;
            AgentTypeBadgeText.Text = error;
            return;
        }

        AgentPromptBox.Text = "";
        AgentTypeBadge.Visibility = Visibility.Collapsed;
    }

    private void OnAgentJobsChanged() => Dispatcher.Invoke(RenderAgentJobList);

    private void RenderAgentJobList()
    {
        AgentJobList.Children.Clear();
        var jobs = AgentJobStore.Shared.Jobs;

        if (jobs.Count == 0)
        {
            AgentJobList.Children.Add(new TextBlock
            {
                Text = "No agent tasks yet — try \"research the history of coffee\" or \"write a short blog post about focus\".",
                Foreground = new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF)),
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
                Margin = new Thickness(0, 24, 0, 0),
            });
            return;
        }

        foreach (var job in jobs) AgentJobList.Children.Add(BuildAgentJobRow(job));
    }

    private UIElement BuildAgentJobRow(AgentJob job)
    {
        var (statusColor, statusLabel) = job.Status switch
        {
            AgentJobStatus.Queued => (Color.FromRgb(0x25, 0x63, 0xEB), "Queued"),
            AgentJobStatus.Running => (Color.FromRgb(0x25, 0x63, 0xEB), "Running…"),
            AgentJobStatus.Completed => (Color.FromRgb(0x34, 0xD3, 0x99), "Completed"),
            AgentJobStatus.Failed => (Color.FromRgb(0xF8, 0x71, 0x71), "Failed"),
            AgentJobStatus.Cancelled => (Color.FromRgb(0x6B, 0x73, 0x6F), "Cancelled"),
            _ => (Colors.White, job.Status.ToString()),
        };

        var headerGrid = new Grid();
        headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var icon = new TextBlock { Text = job.Icon, FontSize = 14, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        Grid.SetColumn(icon, 0);

        var promptText = new TextBlock
        {
            Text = job.Prompt,
            Foreground = System.Windows.Media.Brushes.White,
            FontSize = 12,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(promptText, 1);

        var statusText = new TextBlock
        {
            Text = statusLabel,
            Foreground = new SolidColorBrush(statusColor),
            FontSize = 10,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8, 0, 8, 0),
        };
        Grid.SetColumn(statusText, 2);

        var deleteButton = new Button
        {
            Content = "✕",
            FontSize = 11,
            Width = 20,
            Height = 20,
            Background = System.Windows.Media.Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Foreground = new SolidColorBrush(Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF)),
            Cursor = System.Windows.Input.Cursors.Hand,
            ToolTip = "Remove",
        };
        deleteButton.Click += (_, e) => { e.Handled = true; AgentJobStore.Shared.RemoveJob(job.Id); };
        Grid.SetColumn(deleteButton, 3);

        headerGrid.Children.Add(icon);
        headerGrid.Children.Add(promptText);
        headerGrid.Children.Add(statusText);
        headerGrid.Children.Add(deleteButton);

        var contentStack = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        var bodyText = job.Status switch
        {
            AgentJobStatus.Completed => job.ResultText ?? "",
            AgentJobStatus.Failed => $"Error: {job.ErrorMessage}",
            AgentJobStatus.Cancelled => job.ErrorMessage ?? "Cancelled.",
            _ => "Working…",
        };
        contentStack.Children.Add(new TextBlock
        {
            Text = bodyText,
            Foreground = new SolidColorBrush(Color.FromArgb(0xCC, 0xFF, 0xFF, 0xFF)),
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
        });

        if (!string.IsNullOrEmpty(job.OutputFilePath))
        {
            var path = job.OutputFilePath;
            var openButton = new Button { Content = "Open file", Height = 24, Width = 90, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
            openButton.Click += (_, _) =>
            {
                try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
                catch { /* file may have been moved/deleted since it was written */ }
            };
            contentStack.Children.Add(openButton);
        }

        return new Expander
        {
            Header = headerGrid,
            Content = contentStack,
            Foreground = System.Windows.Media.Brushes.White,
            Background = new SolidColorBrush(Color.FromArgb(0x0D, 0xFF, 0xFF, 0xFF)),
            Margin = new Thickness(0, 0, 0, 6),
            Padding = new Thickness(8),
        };
    }

    // ---- Skills ----

    private void OnSkillsChanged() => Dispatcher.Invoke(RenderSkillsList);

    private void RenderSkillsList()
    {
        var canView = EntitlementService.Shared.Can(Entitlement.ViewSkills);
        SkillsUpsellPanel.Visibility = canView ? Visibility.Collapsed : Visibility.Visible;
        SkillsScroller.Visibility = canView ? Visibility.Visible : Visibility.Collapsed;

        var canCreate = EntitlementService.Shared.Can(Entitlement.CreateSkills);
        SkillCreateButton.Style = (Style)FindResource(canCreate ? "LabsSubTabButtonStyle" : "LabsSubTabButtonStyleDim");
        SkillImportButton.Style = (Style)FindResource(canCreate ? "LabsSubTabButtonStyle" : "LabsSubTabButtonStyleDim");

        if (!canView) return;

        SkillsList.Children.Clear();
        foreach (var skill in SkillStore.Shared.All) SkillsList.Children.Add(BuildSkillRow(skill));
    }

    private UIElement BuildSkillRow(MiraSkill skill)
    {
        var isActive = SkillStore.Shared.IsActive(skill.Id);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var icon = new TextBlock { Text = skill.Icon, FontSize = 16, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
        Grid.SetColumn(icon, 0);

        var textStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        textStack.Children.Add(new TextBlock { Text = skill.Name, Foreground = System.Windows.Media.Brushes.White, FontSize = 12, FontWeight = FontWeights.SemiBold });
        if (!string.IsNullOrEmpty(skill.Tagline))
        {
            textStack.Children.Add(new TextBlock
            {
                Text = skill.Tagline,
                Foreground = new SolidColorBrush(Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF)),
                FontSize = 10,
                Margin = new Thickness(0, 2, 0, 0),
            });
        }
        Grid.SetColumn(textStack, 1);

        var toggleButton = new Button
        {
            Content = isActive ? "On" : "Off",
            Width = 46,
            Height = 24,
            FontSize = 10,
            BorderThickness = new Thickness(0),
            Cursor = System.Windows.Input.Cursors.Hand,
            Foreground = System.Windows.Media.Brushes.White,
            Background = isActive
                ? new SolidColorBrush(Color.FromRgb(0x25, 0x63, 0xEB))
                : new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF)),
        };
        toggleButton.Click += (_, e) => { e.Handled = true; SkillStore.Shared.Toggle(skill.Id); RenderSkillsList(); };
        Grid.SetColumn(toggleButton, 2);

        if (skill.Origin == MiraSkillOrigin.User)
        {
            var deleteButton = new Button
            {
                Content = "✕",
                FontSize = 11,
                Width = 20,
                Height = 20,
                Margin = new Thickness(6, 0, 0, 0),
                Background = System.Windows.Media.Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Foreground = new SolidColorBrush(Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF)),
                Cursor = System.Windows.Input.Cursors.Hand,
                ToolTip = "Remove",
            };
            deleteButton.Click += (_, e) => { e.Handled = true; SkillStore.Shared.RemoveUserSkill(skill.Id); RenderSkillsList(); };
            Grid.SetColumn(deleteButton, 3);
            grid.Children.Add(deleteButton);
        }

        grid.Children.Add(icon);
        grid.Children.Add(textStack);
        grid.Children.Add(toggleButton);

        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0x0D, 0xFF, 0xFF, 0xFF)),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10, 8, 8, 8),
            Margin = new Thickness(0, 0, 0, 6),
            Child = grid,
        };
    }

    private void SkillCreateButton_Click(object sender, RoutedEventArgs e)
    {
        SkillDescriptionBox.Text = "";
        SkillPreviewBorder.Visibility = Visibility.Collapsed;
        _pendingSkillMarkdown = null;
        SkillGenerateStatusText.Text = EntitlementService.Shared.Can(Entitlement.CreateSkills)
            ? "" : "Creating skills needs an Ultra plan.";
        SkillCreatePanel.Visibility = Visibility.Visible;
    }

    private void SkillCreateCancelButton_Click(object sender, RoutedEventArgs e) => SkillCreatePanel.Visibility = Visibility.Collapsed;

    private async void SkillGenerateButton_Click(object sender, RoutedEventArgs e)
    {
        if (!EntitlementService.Shared.Can(Entitlement.CreateSkills))
        {
            SkillGenerateStatusText.Text = "Creating skills needs an Ultra plan.";
            return;
        }

        var description = SkillDescriptionBox.Text.Trim();
        if (string.IsNullOrEmpty(description)) return;

        SkillGenerateStatusText.Text = "Generating…";
        SkillPreviewBorder.Visibility = Visibility.Collapsed;
        try
        {
            var markdown = await SkillAuthor.GenerateAsync(description);
            _pendingSkillMarkdown = markdown;
            SkillPreviewText.Text = markdown;
            SkillPreviewBorder.Visibility = Visibility.Visible;
            SkillGenerateStatusText.Text = "";
        }
        catch (Exception ex)
        {
            SkillGenerateStatusText.Text = $"Couldn't generate a skill: {ex.Message}";
        }
    }

    private void SkillSaveButton_Click(object sender, RoutedEventArgs e)
    {
        if (_pendingSkillMarkdown is null) return;

        var (ok, error) = SkillStore.Shared.CreateSkill(_pendingSkillMarkdown);
        if (!ok)
        {
            SkillGenerateStatusText.Text = error;
            return;
        }

        SkillCreatePanel.Visibility = Visibility.Collapsed;
        RenderSkillsList();
    }

    private void SkillImportButton_Click(object sender, RoutedEventArgs e)
    {
        if (!EntitlementService.Shared.Can(Entitlement.CreateSkills))
        {
            SkillGenerateStatusText.Text = "Importing a skill needs an Ultra plan.";
            SkillCreatePanel.Visibility = Visibility.Visible;
            return;
        }

        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Filter = "SKILL.md files (*.md)|*.md|All files (*.*)|*.*",
            Title = "Import a SKILL.md file",
        };
        if (dialog.ShowDialog() != true) return;

        var (ok, error) = SkillStore.Shared.ImportSkill(dialog.FileName);
        if (!ok)
        {
            SkillGenerateStatusText.Text = error;
            SkillCreatePanel.Visibility = Visibility.Visible;
            return;
        }

        RenderSkillsList();
    }

    // ---- Crons ----

    private void OnCronsChanged() => Dispatcher.Invoke(RenderCronList);

    private void PopulateCronCombos()
    {
        for (var h = 0; h < 24; h++) CronHourCombo.Items.Add(h.ToString("D2"));
        for (var m = 0; m < 60; m++) CronMinuteCombo.Items.Add(m.ToString("D2"));
        string[] weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
        foreach (var name in weekdayNames) CronWeekdayCombo.Items.Add(name);
    }

    private void RenderCronList()
    {
        var crons = CronStore.Shared.Crons;
        CronEmptyPanel.Visibility = crons.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        CronList.Children.Clear();
        foreach (var cron in crons) CronList.Children.Add(BuildCronRow(cron));
    }

    private UIElement BuildCronRow(MiraCron cron)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var dot = new Ellipse
        {
            Width = 8,
            Height = 8,
            Fill = new SolidColorBrush(cron.Enabled ? Color.FromRgb(0x33, 0xD6, 0x4A) : Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 10, 0),
        };
        Grid.SetColumn(dot, 0);

        var textStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        textStack.Children.Add(new TextBlock
        {
            Text = cron.Name,
            Foreground = cron.Enabled ? System.Windows.Media.Brushes.White : new SolidColorBrush(Color.FromArgb(0x66, 0xFF, 0xFF, 0xFF)),
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        var subtitle = cron.LastRunAt is { } last
            ? $"{cron.Schedule.DisplayName} · last {FormatRelativeShort(last)}"
            : cron.Schedule.DisplayName;
        textStack.Children.Add(new TextBlock
        {
            Text = subtitle,
            Foreground = new SolidColorBrush(Color.FromArgb(0x59, 0xFF, 0xFF, 0xFF)),
            FontSize = 10,
            Margin = new Thickness(0, 2, 0, 0),
        });
        Grid.SetColumn(textStack, 1);
        if (!string.IsNullOrEmpty(cron.LastRunResult)) textStack.ToolTip = cron.LastRunResult;

        var nextFireText = new TextBlock
        {
            Text = FormatRelativeShort(cron.NextFireAt),
            Foreground = new SolidColorBrush(Color.FromArgb(0x4D, 0xFF, 0xFF, 0xFF)),
            FontSize = 10,
            FontFamily = new FontFamily("Consolas"),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
        };
        Grid.SetColumn(nextFireText, 2);

        var actions = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };

        var editButton = new Button
        {
            Content = "✎", FontSize = 11, Width = 22, Height = 22,
            Background = System.Windows.Media.Brushes.Transparent, BorderThickness = new Thickness(0),
            Foreground = new SolidColorBrush(Color.FromArgb(0x66, 0xFF, 0xFF, 0xFF)), Cursor = System.Windows.Input.Cursors.Hand, ToolTip = "Edit",
        };
        editButton.Click += (_, e) => { e.Handled = true; OpenCronEditor(cron); };

        var toggleButton = new Button
        {
            Content = cron.Enabled ? "⏸" : "▶", FontSize = 10, Width = 22, Height = 22,
            Background = System.Windows.Media.Brushes.Transparent, BorderThickness = new Thickness(0),
            Foreground = new SolidColorBrush(cron.Enabled ? Color.FromArgb(0x66, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0xB3, 0x33, 0xD6, 0x4A)),
            Cursor = System.Windows.Input.Cursors.Hand, ToolTip = cron.Enabled ? "Pause" : "Resume",
        };
        toggleButton.Click += (_, e) => { e.Handled = true; CronStore.Shared.Toggle(cron.Id); };

        var deleteButton = new Button
        {
            Content = "✕", FontSize = 11, Width = 22, Height = 22,
            Background = System.Windows.Media.Brushes.Transparent, BorderThickness = new Thickness(0),
            Foreground = new SolidColorBrush(Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF)), Cursor = System.Windows.Input.Cursors.Hand, ToolTip = "Delete",
        };
        deleteButton.Click += (_, e) => { e.Handled = true; CronStore.Shared.Delete(cron.Id); };

        actions.Children.Add(editButton);
        actions.Children.Add(toggleButton);
        actions.Children.Add(deleteButton);
        Grid.SetColumn(actions, 3);

        grid.Children.Add(dot);
        grid.Children.Add(textStack);
        grid.Children.Add(nextFireText);
        grid.Children.Add(actions);

        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0x0D, 0xFF, 0xFF, 0xFF)),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 8, 6, 8),
            Margin = new Thickness(0, 0, 0, 6),
            Child = grid,
        };
    }

    /// <summary>Mirrors CronsTabView.swift's <c>Date.relativeShort</c> -- handles both directions (a cron's next-fire is future, its last-run is past).</summary>
    private static string FormatRelativeShort(DateTimeOffset target)
    {
        var diff = DateTimeOffset.UtcNow - target;
        if (diff < TimeSpan.Zero)
        {
            var abs = -diff;
            if (abs.TotalSeconds < 3600) return $"in {(int)abs.TotalMinutes}m";
            if (abs.TotalSeconds < 86400) return $"in {(int)abs.TotalHours}h";
            return $"in {(int)abs.TotalDays}d";
        }
        if (diff.TotalSeconds < 60) return "now";
        if (diff.TotalSeconds < 3600) return $"{(int)diff.TotalMinutes}m ago";
        if (diff.TotalSeconds < 86400) return $"{(int)diff.TotalHours}h ago";
        return $"{(int)diff.TotalDays}d ago";
    }

    private void CronCreateButton_Click(object sender, RoutedEventArgs e) => OpenCronEditor(null);

    private void OpenCronEditor(MiraCron? existing)
    {
        _editingCronId = existing?.Id;
        CronEditorTitleText.Text = existing is null ? "New Scheduled Task" : "Edit Task";
        CronEditorErrorText.Visibility = Visibility.Collapsed;

        CronNameBox.Text = existing?.Name ?? "";
        CronPromptBox.Text = existing?.Prompt ?? "";

        var schedule = existing?.Schedule ?? CronSchedule.Daily(9, 0);
        CronHourCombo.SelectedIndex = schedule.Hour;
        CronMinuteCombo.SelectedIndex = schedule.Minute;
        CronWeekdayCombo.SelectedIndex = Math.Clamp(schedule.Weekday, 1, 7) - 1;
        CronIntervalBox.Text = schedule.IntervalMinutes.ToString();

        SetCronEditorKind(schedule.Kind);
        CronEditorPanel.Visibility = Visibility.Visible;
    }

    private void CronKindButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string tag } && Enum.TryParse<CronScheduleKind>(tag, out var kind))
            SetCronEditorKind(kind);
    }

    private void SetCronEditorKind(CronScheduleKind kind)
    {
        _cronEditorKind = kind;

        CronKindHourlyButton.Style = (Style)FindResource(kind == CronScheduleKind.Hourly ? "LabsSubTabButtonStyle" : "LabsSubTabButtonStyleDim");
        CronKindDailyButton.Style = (Style)FindResource(kind == CronScheduleKind.Daily ? "LabsSubTabButtonStyle" : "LabsSubTabButtonStyleDim");
        CronKindWeeklyButton.Style = (Style)FindResource(kind == CronScheduleKind.Weekly ? "LabsSubTabButtonStyle" : "LabsSubTabButtonStyleDim");
        CronKindCustomButton.Style = (Style)FindResource(kind == CronScheduleKind.Custom ? "LabsSubTabButtonStyle" : "LabsSubTabButtonStyleDim");

        CronHourlyHintText.Visibility = kind == CronScheduleKind.Hourly ? Visibility.Visible : Visibility.Collapsed;
        CronWeekdayRow.Visibility = kind == CronScheduleKind.Weekly ? Visibility.Visible : Visibility.Collapsed;
        CronTimeRow.Visibility = kind is CronScheduleKind.Daily or CronScheduleKind.Weekly ? Visibility.Visible : Visibility.Collapsed;
        CronIntervalRow.Visibility = kind == CronScheduleKind.Custom ? Visibility.Visible : Visibility.Collapsed;
    }

    private CronSchedule BuildCronScheduleFromEditor() => _cronEditorKind switch
    {
        CronScheduleKind.Hourly => CronSchedule.Hourly(),
        CronScheduleKind.Daily => CronSchedule.Daily(CronHourCombo.SelectedIndex, CronMinuteCombo.SelectedIndex),
        CronScheduleKind.Weekly => CronSchedule.Weekly(CronWeekdayCombo.SelectedIndex + 1, CronHourCombo.SelectedIndex, CronMinuteCombo.SelectedIndex),
        CronScheduleKind.Custom => CronSchedule.Custom(int.TryParse(CronIntervalBox.Text, out var m) ? m : 30),
        _ => CronSchedule.Daily(9, 0),
    };

    private void CronSaveButton_Click(object sender, RoutedEventArgs e)
    {
        var name = CronNameBox.Text.Trim();
        var prompt = CronPromptBox.Text.Trim();
        if (name.Length == 0 || prompt.Length == 0)
        {
            CronEditorErrorText.Text = "Both a task name and a prompt are required.";
            CronEditorErrorText.Visibility = Visibility.Visible;
            return;
        }

        var schedule = BuildCronScheduleFromEditor();
        var now = DateTimeOffset.UtcNow;

        if (_editingCronId is { } id)
        {
            var existing = CronStore.Shared.Crons.FirstOrDefault(c => c.Id == id);
            if (existing is not null)
            {
                existing.Name = name;
                existing.Prompt = prompt;
                existing.Schedule = schedule;
                existing.NextFireAt = schedule.NextFire(now);
                CronStore.Shared.Update(existing);
            }
        }
        else
        {
            CronStore.Shared.Add(MiraCron.Create(name, prompt, schedule, now));
        }

        CronEditorPanel.Visibility = Visibility.Collapsed;
    }

    private void CronCancelButton_Click(object sender, RoutedEventArgs e) => CronEditorPanel.Visibility = Visibility.Collapsed;

    // ---- Learn ----

    private void OnLearnChanged() => Dispatcher.Invoke(RenderLearnTab);

    private void RenderLearnTab()
    {
        var running = LessonRunner.Shared.State == LessonRunState.Running;
        LearnRunningPanel.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
        LearnListScroller.Visibility = running ? Visibility.Collapsed : Visibility.Visible;

        if (running) RenderLearnRunning();
        else RenderLearnList();
    }

    private void RenderLearnList()
    {
        LearnLessonList.Children.Clear();
        foreach (var lesson in LessonStore.Shared.All) LearnLessonList.Children.Add(BuildLessonCard(lesson));
    }

    private UIElement BuildLessonCard(Lesson lesson)
    {
        var progress = LessonProgressStore.Shared.Get(lesson.Id);
        var mastered = LessonProgressStore.IsMastered(progress.CompletionCount);
        var reviewDue = LessonProgressStore.IsReviewDue(progress.CompletionCount, progress.LastCompletedAt, DateTimeOffset.UtcNow);
        var inProgress = !mastered && progress.ResumeStepIndex > 0;

        var statusText = reviewDue ? "Review" : mastered ? "Mastered" : inProgress ? "Resume" : "Start";
        var statusColor = reviewDue ? Color.FromRgb(0xF5, 0x9E, 0x0B)
            : mastered ? Color.FromRgb(0x33, 0xD6, 0x4A)
            : new Color { A = 0x59, R = 0xFF, G = 0xFF, B = 0xFF };

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var icon = new TextBlock { Text = "🎓", FontSize = 16, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
        Grid.SetColumn(icon, 0);

        var textStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        textStack.Children.Add(new TextBlock { Text = lesson.Title, Foreground = System.Windows.Media.Brushes.White, FontSize = 12, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        textStack.Children.Add(new TextBlock
        {
            Text = lesson.DomainApp,
            Foreground = new SolidColorBrush(Color.FromArgb(0x59, 0xFF, 0xFF, 0xFF)),
            FontSize = 10,
            Margin = new Thickness(0, 2, 0, 0),
        });
        Grid.SetColumn(textStack, 1);
        textStack.ToolTip = lesson.Description;

        var statusBadge = new TextBlock
        {
            Text = statusText,
            Foreground = new SolidColorBrush(statusColor),
            FontSize = 10,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
        };
        Grid.SetColumn(statusBadge, 2);

        var startButton = new Button { Content = inProgress || reviewDue ? "Resume" : "Start", Width = 60, Height = 24, FontSize = 10, Style = (Style)FindResource("LabsSubTabButtonStyle") };
        startButton.Click += (_, e) => { e.Handled = true; LessonRunner.Shared.Start(lesson, Math.Max(0, progress.ResumeStepIndex)); };
        Grid.SetColumn(startButton, 3);

        grid.Children.Add(icon);
        grid.Children.Add(textStack);
        grid.Children.Add(statusBadge);
        grid.Children.Add(startButton);

        var row = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0x0D, 0xFF, 0xFF, 0xFF)),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 8, 8, 8),
            Margin = new Thickness(0, 0, 0, 6),
            Child = grid,
        };

        if (!lesson.IsBuiltin)
        {
            var context = new ContextMenu();
            var deleteItem = new MenuItem { Header = "Remove lesson" };
            deleteItem.Click += (_, _) => LessonStore.Shared.Remove(lesson.Id);
            context.Items.Add(deleteItem);
            row.ContextMenu = context;
        }

        return row;
    }

    private void RenderLearnRunning()
    {
        var lesson = LessonRunner.Shared.ActiveLesson;
        var step = LessonRunner.Shared.CurrentStep;
        if (lesson is null || step is null) return;

        LearnRunningTitleText.Text = lesson.Title;
        LearnStepProgressText.Text = $"Step {LessonRunner.Shared.CurrentStepIndex + 1} of {lesson.Steps.Count}";
        LearnStepInstructionText.Text = step.Instruction;
        LearnStepRemediationText.Text = step.Remediation ?? "";
        LearnStepRemediationText.Visibility = string.IsNullOrEmpty(step.Remediation) ? Visibility.Collapsed : Visibility.Visible;

        // No self-certify button for an observable step -- mirrors TeachingEngine.swift's
        // honesty invariant: only a genuinely-unobservable (.userConfirmation) step can be
        // marked done by the user, never conflated with a real observation.
        LearnDoneButton.Visibility = step.Check.Kind == LessonCheckKind.UserConfirmation ? Visibility.Visible : Visibility.Collapsed;
        LearnStepWaitingText.Visibility = step.Check.IsObservable ? Visibility.Visible : Visibility.Collapsed;
        LearnStepWaitingText.Text = step.Check.Kind switch
        {
            LessonCheckKind.AppFrontmost => $"Waiting until {step.Check.ProcessName} is the active window…",
            LessonCheckKind.DarkModeEnabled => "Waiting until Dark Mode is turned on…",
            _ => "",
        };
    }

    private void LearnStopButton_Click(object sender, RoutedEventArgs e) => LessonRunner.Shared.Stop();
    private void LearnDoneButton_Click(object sender, RoutedEventArgs e) => LessonRunner.Shared.ConfirmCurrentStep();
    private void LearnSkipButton_Click(object sender, RoutedEventArgs e) => LessonRunner.Shared.SkipCurrentStep();

    private void LearnTeachButton_Click(object sender, RoutedEventArgs e)
    {
        LearnAppNameBox.Text = "";
        LearnProcessNameBox.Text = "";
        LearnGoalBox.Text = "";
        LearnTeachStatusText.Text = "";
        LearnTeachPanel.Visibility = Visibility.Visible;
    }

    private void LearnTeachCancelButton_Click(object sender, RoutedEventArgs e) => LearnTeachPanel.Visibility = Visibility.Collapsed;

    private async void LearnTeachSaveButton_Click(object sender, RoutedEventArgs e)
    {
        var appName = LearnAppNameBox.Text.Trim();
        if (appName.Length == 0)
        {
            LearnTeachStatusText.Text = "An app name is required.";
            return;
        }

        var processName = LearnProcessNameBox.Text.Trim();
        var goal = LearnGoalBox.Text.Trim();

        LearnTeachSaveButton.IsEnabled = false;
        try
        {
            Lesson lesson;
            if (goal.Length == 0)
            {
                lesson = LessonScaffolder.BuildTemplate(appName, processName.Length == 0 ? null : processName);
            }
            else
            {
                LearnTeachStatusText.Text = "Generating…";
                lesson = await LessonAuthor.AuthorAsync(appName, goal);
            }

            var (ok, error) = LessonStore.Shared.Add(lesson);
            if (!ok)
            {
                LearnTeachStatusText.Text = error;
                return;
            }

            LearnTeachPanel.Visibility = Visibility.Collapsed;
            RenderLearnList();
        }
        catch (Exception ex)
        {
            LearnTeachStatusText.Text = $"Couldn't create a lesson: {ex.Message}";
        }
        finally
        {
            LearnTeachSaveButton.IsEnabled = true;
        }
    }

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
                AutonomyGroupSignedInPanel.Visibility = Visibility.Visible;
                var user = AccountService.Shared.CurrentUser;
                SignedInAsText.Text = $"Signed in as {user?.Email ?? user?.DisplayName ?? "(unknown)"}";
                UpdatePlanAndHomeText();
                break;

            case AuthState.SignedOut:
                SettingsSignedOutPanel.Visibility = Visibility.Visible;
                SettingsSignedInPanel.Visibility = Visibility.Collapsed;
                AutonomyGroupSignedInPanel.Visibility = Visibility.Collapsed;
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

    private void ConfirmRiskyCheckBox_Changed(object sender, RoutedEventArgs e) => AutonomySettings.ConfirmRiskyActions = ConfirmRiskyCheckBox.IsChecked == true;

    private void WakeWordCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        var enabled = WakeWordCheckBox.IsChecked == true;
        WakeWordSettings.IsEnabled = enabled;
        if (enabled) WakeWordService.Shared.Start();
        else WakeWordService.Shared.Pause();
    }

    private void CatModeCheckBox_Changed(object sender, RoutedEventArgs e) => PersonalitySettings.CatModeEnabled = CatModeCheckBox.IsChecked == true;

    private void ShowInCaptureCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        var visible = ShowInCaptureCheckBox.IsChecked == true;
        AppearanceSettings.ShowInScreenCaptures = visible;
        CaptureAffinity.Apply(this, visible);
    }

    private void SoundEffectsCheckBox_Changed(object sender, RoutedEventArgs e) =>
        AudioCueSettings.IsMuted = SoundEffectsCheckBox.IsChecked != true;

    private void PopulateBrowserPreferenceCombo()
    {
        BrowserPreferenceCombo.Items.Clear();
        BrowserPreferenceCombo.Items.Add("System default");

        var preferred = BrowserSettings.PreferredBrowserPath;
        var selectedIndex = 0;
        var browsers = InstalledBrowsers.Detect();
        for (var i = 0; i < browsers.Count; i++)
        {
            BrowserPreferenceCombo.Items.Add(browsers[i].Name);
            if (string.Equals(browsers[i].ExePath, preferred, StringComparison.OrdinalIgnoreCase))
                selectedIndex = i + 1;
        }

        BrowserPreferenceCombo.SelectedIndex = selectedIndex;
    }

    private void BrowserPreferenceCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var index = BrowserPreferenceCombo.SelectedIndex;
        if (index <= 0)
        {
            BrowserSettings.PreferredBrowserPath = null;
            return;
        }

        var browsers = InstalledBrowsers.Detect();
        if (index - 1 < browsers.Count) BrowserSettings.PreferredBrowserPath = browsers[index - 1].ExePath;
    }

    private void PrivacyPolicyButton_Click(object sender, RoutedEventArgs e) =>
        BrowserLauncher.Open("https://rdbljrbjsmbfqwwpwwvn.supabase.co/storage/v1/object/public/releases/privacy.html");

    private void TermsButton_Click(object sender, RoutedEventArgs e) =>
        BrowserLauncher.Open("https://rdbljrbjsmbfqwwpwwvn.supabase.co/storage/v1/object/public/releases/terms.html");

    // ---- Voice & Audio ----

    private void PopulateInputDeviceCombo()
    {
        InputDeviceCombo.Items.Clear();
        InputDeviceCombo.Items.Add("System default");

        var preferred = AudioDeviceSettings.PreferredInputDeviceId;
        var selectedIndex = 0;
        var devices = AudioDevices.ListInputDevices();
        for (var i = 0; i < devices.Count; i++)
        {
            InputDeviceCombo.Items.Add(devices[i].Name);
            if (string.Equals(devices[i].Id, preferred, StringComparison.OrdinalIgnoreCase))
                selectedIndex = i + 1;
        }

        InputDeviceCombo.SelectedIndex = selectedIndex;
    }

    private void InputDeviceCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var index = InputDeviceCombo.SelectedIndex;
        if (index <= 0)
        {
            AudioDeviceSettings.PreferredInputDeviceId = null;
            return;
        }

        var devices = AudioDevices.ListInputDevices();
        if (index - 1 < devices.Count) AudioDeviceSettings.PreferredInputDeviceId = devices[index - 1].Id;
    }

    private void PopulateOutputDeviceCombo()
    {
        OutputDeviceCombo.Items.Clear();
        OutputDeviceCombo.Items.Add("System default");

        var preferred = AudioDeviceSettings.PreferredOutputDeviceId;
        var selectedIndex = 0;
        var devices = AudioDevices.ListOutputDevices();
        for (var i = 0; i < devices.Count; i++)
        {
            OutputDeviceCombo.Items.Add(devices[i].Name);
            if (string.Equals(devices[i].Id, preferred, StringComparison.OrdinalIgnoreCase))
                selectedIndex = i + 1;
        }

        OutputDeviceCombo.SelectedIndex = selectedIndex;
    }

    private void OutputDeviceCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var index = OutputDeviceCombo.SelectedIndex;
        if (index <= 0)
        {
            AudioDeviceSettings.PreferredOutputDeviceId = null;
            return;
        }

        var devices = AudioDevices.ListOutputDevices();
        if (index - 1 < devices.Count) AudioDeviceSettings.PreferredOutputDeviceId = devices[index - 1].Id;
    }

    // ---- Memory ----

    private void OnMemoryChanged() => Dispatcher.Invoke(RenderMemoryList);

    private void RenderMemoryList()
    {
        var memories = MemoryStore.Shared.Memories.OrderByDescending(m => m.Confidence).ToList();
        MemoryEmptyText.Visibility = memories.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        MemoryList.Children.Clear();
        foreach (var memory in memories) MemoryList.Children.Add(BuildMemoryRow(memory));
    }

    private UIElement BuildMemoryRow(MemoryModel memory)
    {
        var tierColor = memory.ConfidenceTier switch
        {
            MemoryConfidenceTier.High => Color.FromRgb(0x33, 0xD6, 0x4A),
            MemoryConfidenceTier.Medium => Color.FromRgb(0xF5, 0x9E, 0x0B),
            _ => Color.FromArgb(0x59, 0xFF, 0xFF, 0xFF),
        };

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var dot = new Ellipse { Width = 7, Height = 7, Fill = new SolidColorBrush(tierColor), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        Grid.SetColumn(dot, 0);

        var textStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        textStack.Children.Add(new TextBlock
        {
            Text = memory.Key,
            Foreground = System.Windows.Media.Brushes.White,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        textStack.Children.Add(new TextBlock
        {
            Text = memory.Value,
            Foreground = new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF)),
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 2, 0, 0),
        });
        Grid.SetColumn(textStack, 1);
        textStack.ToolTip = $"{memory.Category} · {memory.ConfidenceTier} confidence";

        var deleteButton = new Button
        {
            Content = "✕", FontSize = 11, Width = 22, Height = 22,
            Background = System.Windows.Media.Brushes.Transparent, BorderThickness = new Thickness(0),
            Foreground = new SolidColorBrush(Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF)), Cursor = System.Windows.Input.Cursors.Hand, ToolTip = "Forget",
        };
        deleteButton.Click += (_, e) => { e.Handled = true; MemoryStore.Shared.Delete(memory.Id); };
        Grid.SetColumn(deleteButton, 2);

        grid.Children.Add(dot);
        grid.Children.Add(textStack);
        grid.Children.Add(deleteButton);

        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0x0D, 0xFF, 0xFF, 0xFF)),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10, 7, 6, 7),
            Margin = new Thickness(0, 0, 0, 6),
            Child = grid,
        };
    }

    private void MemoryClearAllButton_Click(object sender, RoutedEventArgs e) => MemoryClearConfirmPanel.Visibility = Visibility.Visible;

    private void MemoryClearCancelButton_Click(object sender, RoutedEventArgs e) => MemoryClearConfirmPanel.Visibility = Visibility.Collapsed;

    private void MemoryClearConfirmButton_Click(object sender, RoutedEventArgs e)
    {
        MemoryStore.Shared.Clear();
        MemoryClearConfirmPanel.Visibility = Visibility.Collapsed;
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
        AudioCueService.Shared.PlayTextSend();

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
            AudioCueService.Shared.PlayTextReceive();
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

    // ---- Voice (embedded in this tab, not a separate window -- mirrors IslandChatView.swift) ----
    //
    // Conversational, no manual tap needed: once connected, RealtimeVoiceService
    // streams the mic continuously and server-side VAD (not a begin/end button)
    // decides when the user starts and stops talking, mirrors the Swift
    // original's server_vad turn detection exactly -- see that class's own doc
    // comment for the values ported and the one deliberate generalization
    // (applied to every session, not gated behind an isAlwaysOn flag).

    /// <summary>
    /// Expands the island to the Chat tab, then starts voice -- used by the Home
    /// tab's mic button and the Chat tab's own mic button, both of which are
    /// explicit manual clicks the user can only make from an already-visible
    /// panel, so navigating there first is the expected result of the click.
    /// </summary>
    private async Task EnterVoiceModeAsync()
    {
        SetExpanded(true);
        SelectTab(IslandTab.Chat);
        await StartVoiceSessionAsync();
    }

    /// <summary>
    /// Connects a one-off session with no window/tab navigation of its own.
    /// Mirrors NotchManager.swift's <c>.miraActivateVoice</c> handling verbatim:
    /// "intentionally no-op -- mic capture is driven by [voice starting]; island
    /// stays closed" -- on Mac, wake word and the PTT shortcut both start a
    /// session while the pill stays fully collapsed, showing only the collapsed
    /// pill's own Idle/Listening/Speaking eyes+waveform; the expanded panel only
    /// appears if the user separately hovers to open it. Called directly by
    /// wake-word detection for that reason -- <see cref="EnterVoiceModeAsync"/>
    /// (which does force-expand) is only for the two manual mic-button clicks.
    /// </summary>
    private async Task StartVoiceSessionAsync()
    {
        if (_voiceSessionActive) return;

        _voiceSessionActive = true;
        RenderVoiceComposer(VoiceSessionState.Connecting);
        await RealtimeVoiceService.Shared.ConnectAsync();
    }

    /// <summary>Starts the persistent Always-On session -- called at launch (if already enabled) and from the Settings checkbox.</summary>
    private void StartAlwaysOnListening()
    {
        if (_voiceSessionActive) return;

        WakeWordService.Shared.Pause(); // the always-on session already hears everything; no need for a separate wake phrase
        _voiceSessionActive = true;
        RenderVoiceComposer(VoiceSessionState.Connecting);
        _ = RealtimeVoiceService.Shared.ConnectAlwaysOnAsync();
    }

    private void VoiceMicButton_Click(object sender, RoutedEventArgs e) => _ = EnterVoiceModeAsync();

    private async void VoiceCloseButton_Click(object sender, RoutedEventArgs e)
    {
        var wasAlwaysOn = RealtimeVoiceService.Shared.IsAlwaysOnActive;
        _voiceSessionActive = false;
        RenderVoiceComposer(VoiceSessionState.Idle);
        await RealtimeVoiceService.Shared.DisconnectAsync();

        // Manually closing an Always-On session is treated as the user turning
        // the mode off, not a momentary pause -- otherwise it would silently
        // reconnect on the next launch despite the user just having ended it.
        if (wasAlwaysOn)
        {
            VoiceAlwaysOnSettings.IsEnabled = false;
            AlwaysOnCheckBox.IsChecked = false;
            WakeWordService.Shared.Start();
        }
    }

    private void AlwaysOnCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        var enabled = AlwaysOnCheckBox.IsChecked == true;
        VoiceAlwaysOnSettings.IsEnabled = enabled;
        if (enabled)
        {
            StartAlwaysOnListening();
        }
        else if (RealtimeVoiceService.Shared.IsAlwaysOnActive)
        {
            _voiceSessionActive = false;
            RenderVoiceComposer(VoiceSessionState.Idle);
            _ = RealtimeVoiceService.Shared.DisconnectAsync();
            WakeWordService.Shared.Start();
        }
    }

    private void OnVoiceStateChanged(VoiceSessionState state) => Dispatcher.Invoke(() =>
    {
        RenderVoiceComposer(state);

        if (state == VoiceSessionState.Thinking && _voiceAssistantBubble is null)
        {
            _voiceAssistantBubble = new ChatBubbleViewModel(ChatRole.Assistant, "");
            _bubbles.Add(_voiceAssistantBubble);
            Scroller.ScrollToBottom();
        }
        else if (state == VoiceSessionState.Listening && _voiceAssistantBubble is not null)
        {
            // A turn just finished (the session returns to Listening automatically,
            // never Idle, once playback drains or a no-audio response completes) --
            // commit the finished reply to history, same as text chat does.
            _history.Add(new ChatMessage { Role = ChatRole.Assistant, Content = _voiceAssistantBubble.Text });
            _voiceAssistantBubble = null;
        }
    });

    private void OnVoiceTranscriptDelta(string delta) => Dispatcher.Invoke(() =>
    {
        if (_voiceAssistantBubble is null) return;
        _voiceAssistantBubble.Text += delta;
        Scroller.ScrollToBottom();
    });

    private void OnVoiceError(string message) => Dispatcher.Invoke(() =>
    {
        var wasAlwaysOn = RealtimeVoiceService.Shared.IsAlwaysOnActive;
        _voiceSessionActive = false;
        _bubbles.Add(new ChatBubbleViewModel(ChatRole.Assistant, $"Voice error: {message}"));
        Scroller.ScrollToBottom();
        RenderVoiceComposer(VoiceSessionState.Idle);
        if (wasAlwaysOn)
        {
            AlwaysOnCheckBox.IsChecked = false;
            WakeWordService.Shared.Start();
        }
    });

    private void OnVoiceWarning(string message) => Dispatcher.Invoke(() => VoiceStatusText.Text = message);

    private void RenderVoiceComposer(VoiceSessionState state)
    {
        ChatComposerRow.Visibility = _voiceSessionActive ? Visibility.Collapsed : Visibility.Visible;
        VoiceComposerPanel.Visibility = _voiceSessionActive ? Visibility.Visible : Visibility.Collapsed;
        if (!_voiceSessionActive) return;

        VoiceStatusText.Text = state switch
        {
            VoiceSessionState.Connecting => "Connecting…",
            VoiceSessionState.Listening => "Listening…",
            VoiceSessionState.Thinking => "Thinking…",
            VoiceSessionState.Speaking => "Speaking…",
            VoiceSessionState.Error => "Error",
            _ => VoiceStatusText.Text,
        };
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
