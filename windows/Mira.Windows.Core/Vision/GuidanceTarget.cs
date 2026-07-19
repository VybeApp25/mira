namespace Mira.Windows.Core.Vision;

/// <summary>
/// The Windows equivalent of Mira/Models GuidanceTarget — a located UI element
/// that answers a screen_guidance question, produced by <see cref="GuidanceLocator"/>.
/// Carries the screenshot's own pixel dimensions alongside the rect so a
/// consumer can convert into whatever coordinate space it renders in (WPF
/// DIPs) without needing to re-query current screen state, which could have
/// changed since capture.
/// </summary>
public sealed record GuidanceTarget(
    Guid Id,
    PixelRect Rect,
    double Confidence,
    string Label,
    string Explanation,
    int ScreenshotWidth,
    int ScreenshotHeight);
