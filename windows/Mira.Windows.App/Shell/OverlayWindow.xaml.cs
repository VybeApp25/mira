using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Mira.Windows.Core.Vision;
using Point = System.Windows.Point;
using Size = System.Windows.Size;

namespace Mira.Windows.App.Shell;

/// <summary>
/// Full-screen, click-through, always-on-top overlay for the
/// <c>screen_guidance</c> chat route — the Windows equivalent of
/// <c>Mira/Controllers/OverlayWindowController.swift</c>'s <c>showGuidance</c>
/// (highlight box + label + explanation badge, ported from
/// <c>GuidanceOverlayView.swift</c>) combined with <c>PointToService.swift</c>'s
/// flying triangle, since both fire together off the same
/// <see cref="GuidanceTarget"/> in this port (macOS fires them from two
/// separate call sites — chat's screen_guidance route vs. voice's <c>[POINT]</c>
/// parsing — but nothing analogous to the voice-side trigger exists on
/// Windows yet, so combining them here gives both pieces a real, demonstrable
/// trigger without scope-creeping into voice transcript parsing).
///
/// Deliberately narrower than the Mac original for this first pass: no
/// Sharpie-style shape annotations (circle/arrow/underline/bracket — see
/// <c>SharpieOverlayView.swift</c>) and no global "click anywhere, ask about
/// it" monitor (<c>PointFollowUpService.swift</c>) — both are real, separable
/// follow-ups once this core guidance+point-to loop is confirmed working.
/// Primary monitor only, matching the same scope choice already made for the
/// island and the agent-activity chip panel.
/// </summary>
public partial class OverlayWindow : Window
{
    private const int GuidanceDismissSeconds = 10; // matches OverlayWindowController.showGuidance's 10s timer

    private DispatcherTimer? _dismissTimer;

    public OverlayWindow()
    {
        InitializeComponent();

        Left = 0;
        Top = 0;
        Width = SystemParameters.PrimaryScreenWidth;
        Height = SystemParameters.PrimaryScreenHeight;
        RootCanvas.Width = Width;
        RootCanvas.Height = Height;
        PointTo.Width = Width;
        PointTo.Height = Height;

        SourceInitialized += (_, _) => ClickThrough.Apply(this);

        // Pre-warm the HWND (needed for ClickThrough.Apply) without actually
        // showing an empty overlay at startup.
        Show();
        Hide();

        GuidanceOverlayHub.TargetLocated += OnTargetLocated;
        Closed += (_, _) => GuidanceOverlayHub.TargetLocated -= OnTargetLocated;
    }

    private void OnTargetLocated(GuidanceTarget target) => Dispatcher.Invoke(() =>
    {
        // The screenshot GuidanceLocator analyzed may be a different pixel
        // size than this window's own DIPs (GDI capture vs. WPF's 96dpi
        // logical units) -- scale by the ratio rather than assuming 1:1, the
        // same problem Mac solves by dividing by backingScaleFactor.
        var scaleX = Width / target.ScreenshotWidth;
        var scaleY = Height / target.ScreenshotHeight;
        var rect = new Rect(
            target.Rect.X * scaleX, target.Rect.Y * scaleY,
            target.Rect.Width * scaleX, target.Rect.Height * scaleY);

        ShowGuidanceBox(rect, target.Label, target.Explanation);

        var origin = new Point(Width / 2, 16); // top-center, matching the island's own position
        var dest = new Point(rect.Left + rect.Width / 2, rect.Top + rect.Height / 2);
        PointTo.Fly(origin, dest);

        Show();
        _dismissTimer?.Stop();
        _dismissTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(GuidanceDismissSeconds) };
        _dismissTimer.Tick += (_, _) =>
        {
            _dismissTimer!.Stop();
            HideGuidance();
        };
        _dismissTimer.Start();
    });

    private void ShowGuidanceBox(Rect rect, string label, string explanation)
    {
        Canvas.SetLeft(HighlightBox, rect.Left);
        Canvas.SetTop(HighlightBox, rect.Top);
        HighlightBox.Width = rect.Width;
        HighlightBox.Height = rect.Height;
        HighlightBox.Visibility = Visibility.Visible;

        if (string.IsNullOrEmpty(label))
        {
            LabelBadge.Visibility = Visibility.Collapsed;
        }
        else
        {
            LabelText.Text = label;
            LabelBadge.Visibility = Visibility.Visible;
            LabelBadge.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Canvas.SetLeft(LabelBadge, rect.Left + rect.Width / 2 - LabelBadge.DesiredSize.Width / 2);
            Canvas.SetTop(LabelBadge, Math.Max(rect.Top - 30, 4));
        }

        if (string.IsNullOrEmpty(explanation))
        {
            ExplanationBadge.Visibility = Visibility.Collapsed;
        }
        else
        {
            ExplanationText.Text = explanation;
            ExplanationBadge.Visibility = Visibility.Visible;
            ExplanationBadge.Measure(new Size(340, double.PositiveInfinity));
            var left = Math.Clamp(rect.Left + rect.Width / 2 - 170, 8, Width - ExplanationBadge.DesiredSize.Width - 8);
            Canvas.SetLeft(ExplanationBadge, left);
            Canvas.SetTop(ExplanationBadge, Math.Min(rect.Bottom + 12, Height - ExplanationBadge.DesiredSize.Height - 12));
        }
    }

    private void HideGuidance()
    {
        HighlightBox.Visibility = Visibility.Collapsed;
        LabelBadge.Visibility = Visibility.Collapsed;
        ExplanationBadge.Visibility = Visibility.Collapsed;
        Hide();
    }
}
