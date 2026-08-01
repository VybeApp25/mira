using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Mira.Windows.Core.Learn;

/// <summary>
/// The Windows equivalent of <c>NSWorkspace.shared.frontmostApplication</c>,
/// used by <see cref="LessonRunner"/> for <see cref="LessonCheckKind.AppFrontmost"/>
/// steps. Same GetForegroundWindow/GetWindowThreadProcessId pattern already
/// used by <c>Mira.Windows.App/Clipboard/ClipboardWatcher.cs</c>, duplicated
/// here rather than shared: that one lives in the App project because it
/// needs an HWND source to receive window messages, while this needs
/// nothing but the two Win32 calls, so it stays in Core alongside the rest
/// of <see cref="LessonRunner"/>'s state machine.
/// </summary>
public static class ForegroundApp
{
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    public static string? GetForegroundProcessName()
    {
        try
        {
            GetWindowThreadProcessId(GetForegroundWindow(), out var pid);
            return Process.GetProcessById((int)pid).ProcessName;
        }
        catch
        {
            return null;
        }
    }
}
