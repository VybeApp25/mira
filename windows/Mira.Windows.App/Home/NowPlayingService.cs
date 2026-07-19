using Windows.Graphics.Imaging;
using Windows.Media;
using Windows.Media.Control;
using Windows.Storage.Streams;

namespace Mira.Windows.App.Home;

/// <summary>
/// The Windows equivalent of Mira/Services/NowPlayingService.swift — tracks
/// whatever's currently playing system-wide (Spotify, browser tabs, Windows
/// Media Player, etc.) via WinRT's
/// <see cref="GlobalSystemMediaTransportControlsSessionManager"/> (GSMTC),
/// the only Windows API with this capability — there is no classic Win32
/// equivalent to macOS's MediaRemote framework. GSMTC already tracks a single
/// "current" session the same way macOS's <c>MPNowPlayingInfoCenter</c> does,
/// so no extra logic is needed to pick among multiple simultaneously-playing
/// apps.
/// </summary>
public sealed class NowPlayingService
{
    public static NowPlayingService Shared { get; } = new();

    private GlobalSystemMediaTransportControlsSessionManager? _manager;
    private GlobalSystemMediaTransportControlsSession? _session;
    private bool _started;

    /// <summary>Fires whenever any displayed property changes — from a WinRT callback thread, so subscribers must marshal to their own dispatcher.</summary>
    public event Action? Changed;

    public string Title { get; private set; } = "";
    public string Artist { get; private set; } = "";
    public bool HasContent => !string.IsNullOrEmpty(Title);
    public bool IsPlaying { get; private set; }
    public bool IsShuffleActive { get; private set; }
    public bool IsRepeatActive { get; private set; }
    public TimeSpan Position { get; private set; }
    public TimeSpan Duration { get; private set; }
    public byte[]? ThumbnailBgra { get; private set; }
    public int ThumbnailWidth { get; private set; }
    public int ThumbnailHeight { get; private set; }

    private NowPlayingService() { }

    public async Task StartAsync()
    {
        if (_started) return;
        _started = true;

        _manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
        _manager.CurrentSessionChanged += (mgr, _) => AttachSession(mgr.GetCurrentSession());
        AttachSession(_manager.GetCurrentSession());
    }

    private void AttachSession(GlobalSystemMediaTransportControlsSession? session)
    {
        if (_session is not null)
        {
            _session.MediaPropertiesChanged -= OnMediaPropertiesChanged;
            _session.PlaybackInfoChanged -= OnPlaybackInfoChanged;
            _session.TimelinePropertiesChanged -= OnTimelineChanged;
        }

        _session = session;

        if (_session is null)
        {
            Title = "";
            Artist = "";
            ThumbnailBgra = null;
            IsPlaying = false;
            Changed?.Invoke();
            return;
        }

        _session.MediaPropertiesChanged += OnMediaPropertiesChanged;
        _session.PlaybackInfoChanged += OnPlaybackInfoChanged;
        _session.TimelinePropertiesChanged += OnTimelineChanged;

        _ = RefreshMediaPropertiesAsync();
        RefreshPlaybackInfo();
        RefreshTimeline();
    }

    private async void OnMediaPropertiesChanged(GlobalSystemMediaTransportControlsSession s, MediaPropertiesChangedEventArgs e) => await RefreshMediaPropertiesAsync();
    private void OnPlaybackInfoChanged(GlobalSystemMediaTransportControlsSession s, PlaybackInfoChangedEventArgs e) => RefreshPlaybackInfo();
    private void OnTimelineChanged(GlobalSystemMediaTransportControlsSession s, TimelinePropertiesChangedEventArgs e) => RefreshTimeline();

    private async Task RefreshMediaPropertiesAsync()
    {
        if (_session is null) return;
        var props = await _session.TryGetMediaPropertiesAsync();
        Title = props.Title ?? "";
        Artist = props.Artist ?? "";

        ThumbnailBgra = null;
        if (props.Thumbnail is not null)
        {
            try
            {
                using IRandomAccessStreamWithContentType stream = await props.Thumbnail.OpenReadAsync();
                var decoder = await BitmapDecoder.CreateAsync(stream);
                var pixelData = await decoder.GetPixelDataAsync(
                    BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
                    new BitmapTransform(), ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
                ThumbnailBgra = pixelData.DetachPixelData();
                ThumbnailWidth = (int)decoder.PixelWidth;
                ThumbnailHeight = (int)decoder.PixelHeight;
            }
            catch
            {
                ThumbnailBgra = null; // some apps report a thumbnail reference that fails to decode -- no art beats a crash
            }
        }

        Changed?.Invoke();
    }

    private void RefreshPlaybackInfo()
    {
        if (_session is null) return;
        var info = _session.GetPlaybackInfo();
        IsPlaying = info.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
        IsShuffleActive = info.IsShuffleActive ?? false;
        IsRepeatActive = info.AutoRepeatMode is not null && info.AutoRepeatMode != MediaPlaybackAutoRepeatMode.None;
        Changed?.Invoke();
    }

    private void RefreshTimeline()
    {
        if (_session is null) return;
        var t = _session.GetTimelineProperties();
        Position = t.Position;
        Duration = t.EndTime - t.StartTime;
        Changed?.Invoke();
    }

    public async Task TogglePlayPauseAsync()
    {
        if (_session is null) return;
        if (IsPlaying) await _session.TryPauseAsync();
        else await _session.TryPlayAsync();
    }

    public async Task NextTrackAsync() { if (_session is not null) await _session.TrySkipNextAsync(); }
    public async Task PreviousTrackAsync() { if (_session is not null) await _session.TrySkipPreviousAsync(); }
    public async Task ToggleShuffleAsync() { if (_session is not null) await _session.TryChangeShuffleActiveAsync(!IsShuffleActive); }

    public async Task ToggleRepeatAsync()
    {
        if (_session is null) return;
        var next = IsRepeatActive ? MediaPlaybackAutoRepeatMode.None : MediaPlaybackAutoRepeatMode.List;
        await _session.TryChangeAutoRepeatModeAsync(next);
    }

    public async Task SeekAsync(TimeSpan position)
    {
        if (_session is null) return;
        await _session.TryChangePlaybackPositionAsync(position.Ticks);
    }
}
