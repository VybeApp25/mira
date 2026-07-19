namespace Mira.Windows.Core.Chat;

/// <summary>
/// The shape <see cref="RouterHandler"/> needs from a now-playing service to
/// handle <c>music_query</c>/<c>spotify_control</c> — deliberately an
/// interface, not a direct reference, because the real implementation
/// (<c>Mira.Windows.App/Home/NowPlayingService.cs</c>) is built on WinRT's
/// <c>GlobalSystemMediaTransportControlsSessionManager</c>, which needs the
/// App project's <c>net10.0-windows10.0.19041.0</c> target framework — this
/// Core project deliberately stays plain <c>net10.0</c> (see its own csproj
/// comment), so it can't reference WinRT types directly. The App layer
/// assigns <see cref="Current"/> once at startup; until then it's null and
/// the affected routes degrade to an honest "not available" reply rather
/// than throwing.
/// </summary>
public interface INowPlayingBridge
{
    bool HasContent { get; }
    string Title { get; }
    string Artist { get; }
    bool IsPlaying { get; }
    Task TogglePlayPauseAsync();
    Task NextTrackAsync();
    Task PreviousTrackAsync();
}

public static class NowPlayingBridge
{
    public static INowPlayingBridge? Current { get; set; }
}
