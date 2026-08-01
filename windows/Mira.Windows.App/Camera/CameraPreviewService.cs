using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;

namespace Mira.Windows.App.Camera;

/// <summary>
/// The Windows equivalent of Mira/Services/CameraPreviewService.swift — a
/// quick "mirror check" live camera preview, not a full video-conferencing
/// pipeline. macOS uses AVFoundation's <c>AVCaptureSession</c>; the closest
/// Windows analog with no simpler alternative is WinRT's
/// <see cref="MediaCapture"/> + <see cref="MediaFrameReader"/> (there is no
/// classic Win32 webcam API, and third-party wrappers like AForge are
/// unmaintained since ~2013 — reusing the same WinRT plumbing this app
/// already needed for <c>NowPlayingService</c> keeps this native rather than
/// adding a stale dependency). This is why <c>Mira.Windows.App</c>'s
/// TargetFramework became a versioned <c>net10.0-windows10.0.19041.0</c>
/// rather than the plain <c>net10.0-windows</c> it was before — WinRT
/// projection needs a specific Windows SDK contract version, not just "any
/// Windows."
///
/// Frames are exposed as raw premultiplied-BGRA8 pixel buffers rather than
/// any WPF type, since this class has no WPF reference — the Camera tab
/// (App/Shell) converts to a <c>WriteableBitmap</c> on the UI thread.
/// </summary>
public sealed class CameraPreviewService
{
    public static CameraPreviewService Shared { get; } = new();

    private MediaCapture? _capture;
    private MediaFrameReader? _reader;
    private bool _starting;

    /// <summary>Fires with a premultiplied-BGRA8 frame buffer + dimensions on every new camera frame. Fired from a WinRT callback thread — the UI-side subscriber must marshal to its own dispatcher.</summary>
    public event Action<byte[], int, int>? FrameArrived;

    /// <summary>Fires once if starting the camera fails (no camera found, access denied, device busy) — mirrors the Mac tab's "Camera access needed/denied" state.</summary>
    public event Action<string>? StartFailed;

    private CameraPreviewService() { }

    public async Task StartAsync()
    {
        if (_capture is not null || _starting) return;
        _starting = true;

        try
        {
            var groups = await MediaFrameSourceGroup.FindAllAsync();
            var group = groups.FirstOrDefault(g => g.SourceInfos.Any(si => si.SourceKind == MediaFrameSourceKind.Color));
            var colorInfo = group?.SourceInfos.FirstOrDefault(si => si.SourceKind == MediaFrameSourceKind.Color);
            if (group is null || colorInfo is null)
            {
                StartFailed?.Invoke("No camera was found on this PC.");
                return;
            }

            var capture = new MediaCapture();
            await capture.InitializeAsync(new MediaCaptureInitializationSettings
            {
                SourceGroup = group,
                SharingMode = MediaCaptureSharingMode.SharedReadOnly,
                MemoryPreference = MediaCaptureMemoryPreference.Cpu,
                StreamingCaptureMode = StreamingCaptureMode.Video,
            });

            var colorSource = capture.FrameSources[colorInfo.Id];
            var reader = await capture.CreateFrameReaderAsync(colorSource);
            reader.FrameArrived += OnFrameArrived;
            await reader.StartAsync();

            _capture = capture;
            _reader = reader;
        }
        catch (Exception ex)
        {
            // Most commonly: the OS "Let desktop apps access your camera"
            // privacy toggle is off, or another app holds the device exclusively.
            StartFailed?.Invoke($"Couldn't start the camera: {ex.Message}");
            Teardown();
        }
        finally
        {
            _starting = false;
        }
    }

    public void Stop() => Teardown();

    private void Teardown()
    {
        if (_reader is not null)
        {
            _reader.FrameArrived -= OnFrameArrived;
            _reader.Dispose();
            _reader = null;
        }
        _capture?.Dispose();
        _capture = null;
    }

    private void OnFrameArrived(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        using var frame = sender.TryAcquireLatestFrame();
        var software = frame?.VideoMediaFrame?.SoftwareBitmap;
        if (software is null) return;

        SoftwareBitmap? converted = null;
        if (software.BitmapPixelFormat != BitmapPixelFormat.Bgra8 || software.BitmapAlphaMode != BitmapAlphaMode.Premultiplied)
        {
            converted = SoftwareBitmap.Convert(software, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
            software = converted;
        }

        var width = software.PixelWidth;
        var height = software.PixelHeight;
        var buffer = new byte[4 * width * height];
        software.CopyToBuffer(buffer.AsBuffer());
        converted?.Dispose();

        FrameArrived?.Invoke(buffer, width, height);
    }
}
