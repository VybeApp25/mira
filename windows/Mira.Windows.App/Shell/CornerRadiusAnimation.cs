using System.Windows;
using System.Windows.Media.Animation;

namespace Mira.Windows.App.Shell;

/// <summary>
/// WPF has no built-in animation for <see cref="CornerRadius"/> (unlike
/// Double/Color/Point) — this is the standard interpolating implementation so
/// the island's corner radius can animate smoothly alongside its size instead
/// of snapping instantly. Matches the Mac original's own
/// <c>Animatable</c>/<c>AnimatablePair&lt;CGFloat,CGFloat&gt;</c> shape, which
/// independently animates top/bottom radii rather than treating the shape as
/// a stock rounded rectangle.
/// </summary>
public sealed class CornerRadiusAnimation : AnimationTimeline
{
    public static readonly DependencyProperty FromProperty =
        DependencyProperty.Register(nameof(From), typeof(CornerRadius), typeof(CornerRadiusAnimation));

    public static readonly DependencyProperty ToProperty =
        DependencyProperty.Register(nameof(To), typeof(CornerRadius), typeof(CornerRadiusAnimation));

    public CornerRadius From
    {
        get => (CornerRadius)GetValue(FromProperty);
        set => SetValue(FromProperty, value);
    }

    public CornerRadius To
    {
        get => (CornerRadius)GetValue(ToProperty);
        set => SetValue(ToProperty, value);
    }

    /// <summary>When set, drives the interpolation curve so this matches whatever easing the accompanying size animation uses (e.g. the island's <see cref="System.Windows.Media.Animation.BackEase"/>). Falls back to a plain cubic ease-out if unset.</summary>
    public IEasingFunction? EasingFunction { get; set; }

    public override Type TargetPropertyType => typeof(CornerRadius);

    protected override Freezable CreateInstanceCore() => new CornerRadiusAnimation();

    public override object GetCurrentValue(object defaultOriginValue, object defaultDestinationValue, AnimationClock animationClock)
    {
        var progress = animationClock.CurrentProgress ?? 0;
        var eased = EasingFunction?.Ease(progress) ?? 1 - Math.Pow(1 - progress, 3);
        return new CornerRadius(
            Lerp(From.TopLeft, To.TopLeft, eased),
            Lerp(From.TopRight, To.TopRight, eased),
            Lerp(From.BottomRight, To.BottomRight, eased),
            Lerp(From.BottomLeft, To.BottomLeft, eased));
    }

    private static double Lerp(double a, double b, double t) => a + (b - a) * t;
}
