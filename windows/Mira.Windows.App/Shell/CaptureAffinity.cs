using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace Mira.Windows.App.Shell;

/// <summary>
/// The Windows equivalent of macOS's "Show in screen recordings" toggle
/// (SettingsView.swift's Appearance section, <c>mira_show_in_capture</c>) —
/// Windows has a direct, real API for this, unlike several other Appearance
/// toggles ported alongside it: <c>SetWindowDisplayAffinity</c> with
/// <c>WDA_EXCLUDEFROMCAPTURE</c> makes a window invisible to screen capture
/// (recording, sharing, most game-bar/streaming tools) while it stays
/// perfectly normal and visible to the user on their own display.
/// </summary>
public static class CaptureAffinity
{
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);

    private const uint WdaNone = 0x0;
    private const uint WdaExcludeFromCapture = 0x11;

    /// <summary>Call once the window has a real HWND (e.g. in a <c>SourceInitialized</c> handler) — <paramref name="visibleInCaptures"/> mirrors the checkbox's own sense (checked = normal/visible).</summary>
    public static void Apply(Window window, bool visibleInCaptures)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;
        SetWindowDisplayAffinity(hwnd, visibleInCaptures ? WdaNone : WdaExcludeFromCapture);
    }
}
