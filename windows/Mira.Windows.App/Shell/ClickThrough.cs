using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace Mira.Windows.App.Shell;

/// <summary>
/// Makes a window ignore all mouse input, passing clicks straight through to
/// whatever's behind it. The Windows equivalent of the Mac app's
/// <c>AgentActivityChipView</c>, which "deliberately has no buttons/gestures
/// so it stays click-through" — WPF has no built-in way to do this (unlike
/// AppKit's simple hit-test override), so this flips the raw
/// <c>WS_EX_TRANSPARENT</c> extended window style via P/Invoke.
/// </summary>
public static class ClickThrough
{
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TRANSPARENT = 0x00000020;
    private const int WS_EX_LAYERED = 0x00080000;

    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    /// <param name="window">Must already have a live HWND — call from <c>SourceInitialized</c>, not the constructor.</param>
    public static void Apply(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        var exStyle = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, exStyle | WS_EX_TRANSPARENT | WS_EX_LAYERED);
    }
}
