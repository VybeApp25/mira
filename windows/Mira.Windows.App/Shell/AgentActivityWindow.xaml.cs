using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Mira.Windows.Core.Vision;

namespace Mira.Windows.App.Shell;

/// <summary>
/// Floating, click-through, bottom-right-anchored panel visualizing live
/// computer-use steps as they execute — the Windows equivalent of the Mac
/// app's ephemeral "AgentActivity" chips (<c>AgentActivityChipView</c>,
/// <c>AgentTaskManager</c>). Deliberately narrower than the Mac original for
/// this pass: Windows has no persisted "AgentJob" system yet (no website
/// builder, research tasks, etc. are implemented — see
/// <see cref="Chat.RouterHandler"/>'s route coverage), so there is nothing to
/// back the Mac app's OTHER chip family (`FloatingAgentChipView`, backed by
/// `AgentJobStore`). This window only ever shows what
/// <see cref="ComputerUseOrchestrator"/> is actually doing, right now.
///
/// Single instance, single (primary) monitor for this pass — the Mac app
/// hosts one chip panel per <c>NSScreen</c>; multi-monitor support is a real
/// follow-up, not built here.
/// </summary>
public partial class AgentActivityWindow : Window
{
    private const int MaxVisibleSteps = 5;
    private const int DismissDelayMs = 1800; // matches AgentTaskManager.dismissDelay on macOS

    private readonly ObservableCollection<string> _steps = new();
    private DispatcherTimer? _dismissTimer;

    public AgentActivityWindow()
    {
        InitializeComponent();
        StepsList.ItemsSource = _steps;

        SizeChanged += (_, _) => Reposition();
        SourceInitialized += (_, _) => ClickThrough.Apply(this);

        // Pre-warm the HWND (needed for ClickThrough.Apply) without actually
        // showing an empty panel at startup.
        Show();
        Hide();

        ComputerUseOrchestrator.Shared.TaskStarted += OnTaskStarted;
        ComputerUseOrchestrator.Shared.StepCompleted += OnStepCompleted;
        ComputerUseOrchestrator.Shared.TaskFinished += OnTaskFinished;
        Closed += (_, _) =>
        {
            ComputerUseOrchestrator.Shared.TaskStarted -= OnTaskStarted;
            ComputerUseOrchestrator.Shared.StepCompleted -= OnStepCompleted;
            ComputerUseOrchestrator.Shared.TaskFinished -= OnTaskFinished;
        };
    }

    private void Reposition()
    {
        var workArea = SystemParameters.WorkArea;
        Left = workArea.Right - Width - 16;
        Top = workArea.Bottom - ActualHeight - 16;
    }

    private void OnTaskStarted() => Dispatcher.Invoke(() =>
    {
        _dismissTimer?.Stop();
        BeginAnimation(OpacityProperty, null);
        _steps.Clear();
        Opacity = 1;
        Show();
        Reposition();
    });

    private void OnStepCompleted(ComputerUseStep step) => Dispatcher.Invoke(() =>
    {
        _steps.Add(string.IsNullOrEmpty(step.Details) ? step.Action : step.Details);
        while (_steps.Count > MaxVisibleSteps) _steps.RemoveAt(0);
    });

    private void OnTaskFinished() => Dispatcher.Invoke(() =>
    {
        _dismissTimer?.Stop();
        _dismissTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(DismissDelayMs) };
        _dismissTimer.Tick += (_, _) =>
        {
            _dismissTimer!.Stop();
            var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(300));
            fade.Completed += (_, _) =>
            {
                Hide();
                _steps.Clear();
            };
            BeginAnimation(OpacityProperty, fade);
        };
        _dismissTimer.Start();
    });
}
