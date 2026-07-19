using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using Mira.Windows.Core.Clipboard;

namespace Mira.Windows.App.Clipboard;

/// <summary>
/// The Windows equivalent of the "read what changed on the clipboard" half of
/// Mira/Services/ClipboardMonitorService.swift — reacts to the real Win32
/// <c>WM_CLIPBOARDUPDATE</c> message instead of polling
/// <c>NSPasteboard.changeCount</c> every 0.5s the way macOS has to (there's
/// no pasteboard-changed notification on macOS; Windows has had a real one,
/// <c>AddClipboardFormatListener</c>, since Vista). The history/dedup/persist
/// logic itself lives in <see cref="ClipboardHistoryStore"/> (Core, no UI
/// dependency); this class only does the OS-specific "what's actually on the
/// clipboard right now" read, which needs WPF's <c>System.Windows.Clipboard</c>.
/// </summary>
public sealed class ClipboardWatcher
{
    private const int WM_CLIPBOARDUPDATE = 0x031D;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool AddClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    private HwndSource? _source;

    /// <param name="window">Must already be shown (have a live HWND) — call from <c>SourceInitialized</c>, same requirement as <see cref="Shell.GlobalHotkey"/>.</param>
    public void Start(Window window)
    {
        _source = (HwndSource)(PresentationSource.FromVisual(window)
            ?? throw new InvalidOperationException("Window must be shown before starting the clipboard watcher."));
        _source.AddHook(WndProc);
        AddClipboardFormatListener(_source.Handle);
    }

    public void Stop()
    {
        if (_source is null) return;
        RemoveClipboardFormatListener(_source.Handle);
        _source.RemoveHook(WndProc);
        _source = null;
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_CLIPBOARDUPDATE) CaptureCurrentClipboard();
        return IntPtr.Zero;
    }

    private static void CaptureCurrentClipboard()
    {
        try
        {
            var sourceApp = GetForegroundProcessName();
            var now = DateTimeOffset.UtcNow;

            if (System.Windows.Clipboard.ContainsImage())
            {
                var bitmap = System.Windows.Clipboard.GetImage();
                if (bitmap is null) return;
                var png = EncodePng(bitmap);
                ClipboardHistoryStore.Shared.Add(new ClipboardItem
                {
                    Id = Guid.NewGuid(), Kind = ClipboardItemKind.Image, ImagePng = png,
                    SourceApp = sourceApp, CopiedAt = now,
                });
                return;
            }

            if (System.Windows.Clipboard.ContainsFileDropList())
            {
                var files = System.Windows.Clipboard.GetFileDropList().Cast<string>().ToList();
                if (files.Count == 0) return;
                ClipboardHistoryStore.Shared.Add(new ClipboardItem
                {
                    Id = Guid.NewGuid(), Kind = ClipboardItemKind.File, FilePaths = files,
                    SourceApp = sourceApp, CopiedAt = now,
                });
                return;
            }

            if (System.Windows.Clipboard.ContainsText())
            {
                var text = System.Windows.Clipboard.GetText();
                if (string.IsNullOrEmpty(text)) return;
                ClipboardHistoryStore.Shared.Add(new ClipboardItem
                {
                    Id = Guid.NewGuid(), Kind = ClipboardItem.Classify(text), Text = text,
                    SourceApp = sourceApp, CopiedAt = now,
                });
            }
        }
        catch
        {
            // The clipboard is a shared system resource another process can hold
            // (CLIPBRD_E_CANT_OPEN) -- skip this update rather than throwing on a
            // WM_CLIPBOARDUPDATE handler, which would take the whole app down.
        }
    }

    private static string? GetForegroundProcessName()
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

    private static byte[] EncodePng(BitmapSource bitmap)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var ms = new MemoryStream();
        encoder.Save(ms);
        return ms.ToArray();
    }
}
