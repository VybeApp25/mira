using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace Mira.Windows.App.Shell;

/// <summary>
/// The Windows equivalent of the Mac app's Carbon global shortcuts
/// (Mira/Managers/GlobalShortcutManager.swift's <c>RegisterEventHotKey</c>) —
/// works system-wide with no Accessibility-style permission needed, same as
/// the Mac original. Needs a real HWND to receive <c>WM_HOTKEY</c>, so this
/// hooks whatever window it's given (the island window) rather than creating
/// a separate hidden message-only window.
/// </summary>
public sealed class GlobalHotkey : IDisposable
{
    public const uint ModAlt = 0x0001;
    public const uint ModControl = 0x0002;
    public const uint ModShift = 0x0004;
    public const uint VkT = 0x54;
    public const uint VkV = 0x56;

    private const int WM_HOTKEY = 0x0312;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private readonly HwndSource _source;
    private readonly int _id;
    private bool _disposed;

    public event Action? Pressed;

    /// <param name="window">Must already be shown (have a live HWND) — construct this after <c>Show()</c>, not before.</param>
    public GlobalHotkey(Window window, int id, uint modifiers, uint virtualKey)
    {
        _id = id;
        _source = (HwndSource)(PresentationSource.FromVisual(window)
            ?? throw new InvalidOperationException("Window must be shown before registering a global hotkey."));
        _source.AddHook(WndProc);

        if (!RegisterHotKey(_source.Handle, _id, modifiers, virtualKey))
            throw new InvalidOperationException("Couldn't register the global hotkey — it may already be in use by another app.");
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_HOTKEY && wParam.ToInt32() == _id)
        {
            Pressed?.Invoke();
            handled = true;
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        UnregisterHotKey(_source.Handle, _id);
        _source.RemoveHook(WndProc);
    }
}
