using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace Mira.Windows.Core.Vision;

/// <summary>
/// The Windows equivalent of Mira/Services/ComputerUseService.swift's screenshot
/// half — captures the primary display for the Anthropic computer-use vision
/// loop, and a tiny grayscale fingerprint for cheap before/after change detection.
///
/// Uses GDI (<see cref="Graphics.CopyFromScreen"/>), NOT Windows.Graphics.Capture
/// (the WinRT API named in docs/windows/WINDOWS_ARCHITECTURE.md/FEATURE_PARITY_MATRIX.md
/// as the modern replacement for ScreenCaptureKit) — a deliberate scope choice,
/// not an oversight: Windows.Graphics.Capture requires WinRT projection interop
/// from this plain WPF app (via CsWinRT) and, in most integration patterns, a
/// picker UI or window-handle capture-item setup considerably more involved than
/// a straight screenshot call. GDI capture is simpler and reliable for the
/// "grab a full-screen JPEG for a vision model" use case this loop actually
/// needs. The tradeoff worth naming: Windows.Graphics.Capture shows a system
/// "you are being captured" indicator per session — a real, more-visible-than-macOS
/// consent moment (see docs/windows/SECURITY_AND_PRIVACY.md §5) that plain GDI
/// capture does not provide. Revisit if that visibility becomes a priority.
/// </summary>
public static class ScreenCapture
{
    // Win32 GetSystemMetrics rather than System.Windows.SystemParameters (WPF) or
    // System.Windows.Forms.Screen (WinForms) — this project references neither UI
    // framework, and a raw P/Invoke keeps it that way rather than pulling one in
    // just to read two screen-size integers.
    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    private const int SM_CXSCREEN = 0;
    private const int SM_CYSCREEN = 1;

    public static int DisplayWidth => GetSystemMetrics(SM_CXSCREEN);
    public static int DisplayHeight => GetSystemMetrics(SM_CYSCREEN);

    /// <summary>Full-primary-display screenshot as JPEG bytes (quality 75, matching the macOS client's own downsampling-for-cost tradeoff).</summary>
    public static byte[]? CaptureJpeg()
    {
        using var bitmap = CaptureBitmap(DisplayWidth, DisplayHeight);
        if (bitmap is null) return null;
        return EncodeJpeg(bitmap, quality: 75L);
    }

    /// <summary>
    /// A tiny grayscale fingerprint (96x60, matching the Swift original's exact
    /// dimensions) for cheap before/after screen-change detection — confirms an
    /// action actually did something before the model is told it "worked."
    /// </summary>
    public static byte[]? CaptureFingerprint()
    {
        using var full = CaptureBitmap(DisplayWidth, DisplayHeight);
        if (full is null) return null;
        using var small = new Bitmap(96, 60);
        using (var g = Graphics.FromImage(small))
            g.DrawImage(full, 0, 0, 96, 60);

        var bytes = new byte[96 * 60];
        var data = small.LockBits(new Rectangle(0, 0, 96, 60), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            unsafe
            {
                var ptr = (byte*)data.Scan0;
                for (var y = 0; y < 60; y++)
                {
                    var row = ptr + y * data.Stride;
                    for (var x = 0; x < 96; x++)
                    {
                        var b = row[x * 4]; var gr = row[x * 4 + 1]; var r = row[x * 4 + 2];
                        bytes[y * 96 + x] = (byte)((r * 299 + gr * 587 + b * 114) / 1000); // luminance
                    }
                }
            }
        }
        finally { small.UnlockBits(data); }
        return bytes;
    }

    /// <summary>Fraction of fingerprint samples that changed by more than <paramref name="tolerance"/> — ~0 means the screen didn't visibly move.</summary>
    public static double ChangedFraction(byte[] a, byte[] b, int tolerance = 24)
    {
        if (a.Length != b.Length || a.Length == 0) return 1;
        var changed = 0;
        for (var i = 0; i < a.Length; i++)
            if (Math.Abs(a[i] - b[i]) > tolerance) changed++;
        return (double)changed / a.Length;
    }

    private static Bitmap? CaptureBitmap(int width, int height)
    {
        try
        {
            var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
            using var g = Graphics.FromImage(bitmap);
            g.CopyFromScreen(0, 0, 0, 0, new Size(width, height), CopyPixelOperation.SourceCopy);
            return bitmap;
        }
        catch
        {
            return null;
        }
    }

    private static byte[] EncodeJpeg(Bitmap bitmap, long quality)
    {
        var encoder = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(Encoder.Quality, quality);
        using var ms = new MemoryStream();
        bitmap.Save(ms, encoder, parameters);
        return ms.ToArray();
    }
}
