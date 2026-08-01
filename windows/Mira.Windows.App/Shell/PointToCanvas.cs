using System.Windows;
using System.Windows.Media;
using Point = System.Windows.Point;
using Color = System.Windows.Media.Color;
using Pen = System.Windows.Media.Pen;

namespace Mira.Windows.App.Shell;

/// <summary>
/// The flying-triangle "point-to" animation — ported line-for-line from
/// <c>Mira/Services/PointToService.swift</c>'s <c>_TriangleCanvas</c>, whose
/// own comment says the animation spec was "reverse-engineered from
/// HeyClicky's ClickyComputerUseRuntime": cubic bezier (start_handle=0.3,
/// end_handle=0.3, arc_size=0.25, arc_flow=0.0), 750ms glide, spring=0.72
/// rotation settling, 380ms fade starting at 900ms. Every constant below is
/// copied exactly from that source, not re-tuned.
///
/// WPF has no SwiftUI-style declarative <c>TimelineView</c>, so this is a
/// custom <see cref="FrameworkElement"/> with a manual <see cref="OnRender"/>
/// override, redrawn every frame via <see cref="CompositionTarget.Rendering"/>
/// while a flight is in progress (unhooked once it finishes, so it costs
/// nothing while idle).
/// </summary>
public sealed class PointToCanvas : FrameworkElement
{
    private const double GlideDur = 0.750;
    private const double FadeAt = 0.900;
    private const double FadeDur = 0.380;

    private static readonly Color Teal = Color.FromRgb(0x0D, 0xCC, 0xC0); // miraTeale, DesignSystem.swift

    private Point _origin, _dest, _c1, _c2;
    private DateTime? _start;

    /// <summary>Starts a flight from <paramref name="origin"/> (screen DIPs) to <paramref name="dest"/> (screen DIPs) — mirrors <c>PointToService.point(toNormalized:)</c>'s <c>fire</c>.</summary>
    public void Fly(Point origin, Point dest)
    {
        _origin = origin;
        _dest = dest;
        (_c1, _c2) = ComputeBezier(origin, dest);
        _start = DateTime.UtcNow;
        CompositionTarget.Rendering -= OnRendering;
        CompositionTarget.Rendering += OnRendering;
    }

    private void OnRendering(object? sender, EventArgs e)
    {
        InvalidateVisual();
        if (_start is null) return;
        var elapsed = (DateTime.UtcNow - _start.Value).TotalSeconds;
        if (elapsed > FadeAt + FadeDur)
        {
            CompositionTarget.Rendering -= OnRendering;
            _start = null;
        }
    }

    protected override void OnRender(DrawingContext dc)
    {
        if (_start is null) return;
        var elapsed = (DateTime.UtcNow - _start.Value).TotalSeconds;

        var t = EaseInOut(Math.Min(1.0, elapsed / GlideDur));
        var alpha = elapsed <= FadeAt ? 1.0 : Math.Max(0, 1 - (elapsed - FadeAt) / FadeDur);
        if (alpha <= 0.01) return;

        var pos = CubicBezier(t);
        var tangent = CubicBezierTangent(t);
        var rawAngle = Math.Atan2(tangent.Y, tangent.X);

        // Spring-damp the rotation as the cursor approaches the target
        // (HeyClicky spring=0.72) -- blend toward the final rest angle past t=0.8.
        var finalAngle = Math.Atan2(_dest.Y - _c2.Y, _dest.X - _c2.X);
        var blend = Math.Max(0, (t - 0.80) / 0.20);
        var angle = rawAngle * (1 - blend) + finalAngle * blend;

        // Scale rises 1 -> 1.7 at mid-flight, back to 1 at destination.
        var scale = 1.0 + Math.Sin(t * Math.PI) * 0.70;

        var glowR = 14 * scale;
        var glowBrush = new SolidColorBrush(Teal) { Opacity = alpha * 0.18 };
        dc.DrawEllipse(glowBrush, null, pos, glowR, glowR);

        var triBrush = new SolidColorBrush(Teal) { Opacity = alpha };
        dc.DrawGeometry(triBrush, null, TrianglePath(pos, angle, 10 * scale));

        // Arrival ring: expands and fades as the triangle lands.
        if (t > 0.78)
        {
            var phase = (t - 0.78) / 0.22;
            var rr = 8 + phase * 18;
            var pen = new Pen(new SolidColorBrush(Teal) { Opacity = alpha * (1 - phase) * 0.60 }, 1.5);
            dc.DrawEllipse(null, pen, _dest, rr, rr);
        }

        // Second, subtler ring with a slight delay for the "ripple" feel.
        if (t > 0.86)
        {
            var phase2 = (t - 0.86) / 0.14;
            var rr2 = 14 + phase2 * 14;
            var pen2 = new Pen(new SolidColorBrush(Teal) { Opacity = alpha * (1 - phase2) * 0.30 }, 1.0);
            dc.DrawEllipse(null, pen2, _dest, rr2, rr2);
        }
    }

    // ---- Bezier math (exact port of the Swift original) ----

    private static (Point c1, Point c2) ComputeBezier(Point p0, Point p1)
    {
        var dx = p1.X - p0.X;
        var dy = p1.Y - p0.Y;
        var dist = Math.Sqrt(dx * dx + dy * dy);
        if (dist <= 1) return (p0, p1);

        var nx = -dy / dist;
        var ny = dx / dist;
        var deflect = dist * 0.25; // arc_size = 0.25

        var c1 = new Point(p0.X + 0.3 * dx + deflect * nx, p0.Y + 0.3 * dy + deflect * ny);
        var c2 = new Point(p1.X - 0.3 * dx + deflect * nx, p1.Y - 0.3 * dy + deflect * ny);
        return (c1, c2);
    }

    private Point CubicBezier(double t)
    {
        var mt = 1 - t;
        var x = mt * mt * mt * _origin.X + 3 * mt * mt * t * _c1.X + 3 * mt * t * t * _c2.X + t * t * t * _dest.X;
        var y = mt * mt * mt * _origin.Y + 3 * mt * mt * t * _c1.Y + 3 * mt * t * t * _c2.Y + t * t * t * _dest.Y;
        return new Point(x, y);
    }

    private Point CubicBezierTangent(double t)
    {
        var mt = 1 - t;
        var x = 3 * mt * mt * (_c1.X - _origin.X) + 6 * mt * t * (_c2.X - _c1.X) + 3 * t * t * (_dest.X - _c2.X);
        var y = 3 * mt * mt * (_c1.Y - _origin.Y) + 6 * mt * t * (_c2.Y - _c1.Y) + 3 * t * t * (_dest.Y - _c2.Y);
        return new Point(x, y);
    }

    private static double EaseInOut(double t) => t < 0.5 ? 2 * t * t : 1 - Math.Pow(-2 * t + 2, 2) / 2;

    // Equilateral triangle centered at `pos`, pointing in direction `angle`.
    private static Geometry TrianglePath(Point pos, double angle, double size)
    {
        var h = size;
        var hw = size * 0.65;

        var tip = new Point(pos.X + h * Math.Cos(angle), pos.Y + h * Math.Sin(angle));
        var bl = new Point(
            pos.X - hw * Math.Sin(angle) - h * 0.4 * Math.Cos(angle),
            pos.Y + hw * Math.Cos(angle) - h * 0.4 * Math.Sin(angle));
        var br = new Point(
            pos.X + hw * Math.Sin(angle) - h * 0.4 * Math.Cos(angle),
            pos.Y - hw * Math.Cos(angle) - h * 0.4 * Math.Sin(angle));

        var geo = new StreamGeometry();
        using (var ctx = geo.Open())
        {
            ctx.BeginFigure(tip, true, true);
            ctx.LineTo(bl, true, false);
            ctx.LineTo(br, true, false);
        }
        geo.Freeze();
        return geo;
    }
}
