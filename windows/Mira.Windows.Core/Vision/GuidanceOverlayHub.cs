namespace Mira.Windows.Core.Vision;

/// <summary>
/// Fire-and-forget event bridge from Core's routing logic to the App's WPF
/// overlay window. <see cref="Chat.RouterHandler"/> lives in Core, which has
/// no WPF reference and can't show a window directly — so it publishes here,
/// and <c>Mira.Windows.App.Shell.OverlayWindow</c> subscribes and renders.
/// </summary>
public static class GuidanceOverlayHub
{
    public static event Action<GuidanceTarget>? TargetLocated;

    public static void Publish(GuidanceTarget target) => TargetLocated?.Invoke(target);
}
