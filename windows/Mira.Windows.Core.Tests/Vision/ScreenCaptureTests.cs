using Mira.Windows.Core.Vision;
using Xunit;

namespace Mira.Windows.Core.Tests.Vision;

/// <summary>
/// Read-only, non-disruptive: capturing the screen doesn't move the mouse or
/// type anything, so these run safely as ordinary tests (unlike anything that
/// would exercise SyntheticInput's actual click/type/key primitives — those
/// take over real input devices and need the user's own go-ahead first).
/// </summary>
public class ScreenCaptureTests
{
    [Fact]
    public void CaptureJpeg_ProducesNonEmptyValidJpegBytes()
    {
        var jpeg = ScreenCapture.CaptureJpeg();
        Assert.NotNull(jpeg);
        Assert.True(jpeg!.Length > 100, "expected a real screenshot, not a near-empty buffer");
        // JPEG files start with the SOI marker 0xFFD8.
        Assert.Equal(0xFF, jpeg[0]);
        Assert.Equal(0xD8, jpeg[1]);
    }

    [Fact]
    public void CaptureFingerprint_Produces96x60Bytes()
    {
        var fp = ScreenCapture.CaptureFingerprint();
        Assert.NotNull(fp);
        Assert.Equal(96 * 60, fp!.Length);
    }

    [Fact]
    public void ChangedFraction_IsZero_ForIdenticalArrays()
    {
        var a = new byte[] { 10, 20, 30, 40 };
        var b = new byte[] { 10, 20, 30, 40 };
        Assert.Equal(0.0, ScreenCapture.ChangedFraction(a, b));
    }

    [Fact]
    public void ChangedFraction_IsOne_WhenEverySampleExceedsTolerance()
    {
        var a = new byte[] { 0, 0, 0, 0 };
        var b = new byte[] { 200, 200, 200, 200 };
        Assert.Equal(1.0, ScreenCapture.ChangedFraction(a, b, tolerance: 24));
    }

    [Fact]
    public void ChangedFraction_IsHalf_WhenHalfTheSamplesChange()
    {
        var a = new byte[] { 0, 0, 100, 100 };
        var b = new byte[] { 0, 0, 200, 200 }; // last two differ by 100, well over tolerance
        Assert.Equal(0.5, ScreenCapture.ChangedFraction(a, b, tolerance: 24));
    }

    [Fact]
    public void ChangedFraction_ReturnsOne_ForMismatchedLengthsOrEmpty()
    {
        Assert.Equal(1.0, ScreenCapture.ChangedFraction(Array.Empty<byte>(), Array.Empty<byte>()));
        Assert.Equal(1.0, ScreenCapture.ChangedFraction(new byte[] { 1 }, new byte[] { 1, 2 }));
    }
}
