namespace Mira.Windows.Core.Vision;

/// <summary>A rectangle in screenshot-pixel space (top-left origin) — the Windows equivalent of Mira/Models GuidanceTarget's <c>CGRect</c>. Core has no WPF reference, so this stays a plain data type; the App layer converts to WPF DIPs.</summary>
public readonly record struct PixelRect(double X, double Y, double Width, double Height)
{
    public double MidX => X + Width / 2;
    public double MidY => Y + Height / 2;
}
