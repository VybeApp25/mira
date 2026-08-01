using System.Security.Cryptography;
using System.Text;
using Mira.Windows.Core.Storage;
using Newtonsoft.Json;

namespace Mira.Windows.Core.Clipboard;

/// <summary>
/// The Windows equivalent of Mira/Services/ClipboardMonitorService.swift's
/// history-management half (add/dedup/pin/delete/persist/AI-context) —
/// deliberately split from the "read what changed off the OS clipboard" half,
/// which needs WPF's <c>System.Windows.Clipboard</c> and so lives in
/// <c>Mira.Windows.App.Clipboard.ClipboardWatcher</c> instead. This class has
/// no UI-framework reference and is fully unit-testable.
///
/// One real improvement over the Mac original, not just a port: macOS has no
/// pasteboard-changed notification, so <c>ClipboardMonitorService</c> polls
/// <c>NSPasteboard.general.changeCount</c> every 0.5s. Windows has a real
/// <c>WM_CLIPBOARDUPDATE</c> message (see <c>ClipboardWatcher</c>), so this
/// port reacts instantly instead of polling.
/// </summary>
public sealed class ClipboardHistoryStore
{
    public static ClipboardHistoryStore Shared { get; } = new();

    private const int MaxItems = 500;
    private const string FileName = "clipboard_history.json";

    private readonly List<ClipboardItem> _history = new();
    private readonly object _gate = new();

    public event Action? Changed;

    private ClipboardHistoryStore() => Load();

    /// <summary>Newest first, matching the Mac list's display order.</summary>
    public IReadOnlyList<ClipboardItem> History
    {
        get { lock (_gate) return _history.ToList(); }
    }

    /// <summary>
    /// Adds a new clip, removing any existing unpinned duplicate first (same
    /// dedup-by-content-hash rule as <c>addItem(_:)</c>), then trims to
    /// <see cref="MaxItems"/> while always keeping pinned items.
    /// </summary>
    public void Add(ClipboardItem item)
    {
        lock (_gate)
        {
            var result = ApplyAdd(_history, item, MaxItems);
            _history.Clear();
            _history.AddRange(result);
        }
        Persist();
        Changed?.Invoke();
    }

    /// <summary>
    /// The pure add/dedup/trim algorithm, extracted so it's directly
    /// unit-testable without touching the singleton or disk — mirrors
    /// <c>addItem(_:)</c>'s exact rules: drop any existing unpinned duplicate
    /// (same kind + same content hash) before inserting the new item at the
    /// front, then trim to <paramref name="maxItems"/> while always keeping
    /// every pinned item regardless of count.
    /// </summary>
    public static List<ClipboardItem> ApplyAdd(IReadOnlyList<ClipboardItem> current, ClipboardItem newItem, int maxItems)
    {
        var hash = Hash(newItem.Text ?? "");
        var deduped = current.Where(i => i.IsPinned || i.Kind != newItem.Kind || Hash(i.Text ?? "") != hash).ToList();
        deduped.Insert(0, newItem);

        var pinned = deduped.Where(i => i.IsPinned).ToList();
        var unpinned = deduped.Where(i => !i.IsPinned).Take(Math.Max(0, maxItems - pinned.Count));
        return pinned.Concat(unpinned).ToList();
    }

    public void Delete(Guid id)
    {
        lock (_gate) _history.RemoveAll(i => i.Id == id);
        Persist();
        Changed?.Invoke();
    }

    public void TogglePin(Guid id)
    {
        lock (_gate)
        {
            var item = _history.FirstOrDefault(i => i.Id == id);
            if (item is not null) item.IsPinned = !item.IsPinned;
        }
        Persist();
        Changed?.Invoke();
    }

    public void SetLabel(Guid id, string? label)
    {
        lock (_gate)
        {
            var item = _history.FirstOrDefault(i => i.Id == id);
            if (item is not null) item.Label = string.IsNullOrEmpty(label) ? null : label;
        }
        Persist();
        Changed?.Invoke();
    }

    public void Clear(bool keepPinned = true)
    {
        lock (_gate)
        {
            if (keepPinned) _history.RemoveAll(i => !i.IsPinned);
            else _history.Clear();
        }
        Persist();
        Changed?.Invoke();
    }

    /// <summary>Up to <paramref name="max"/> recent text-like clips, formatted for prompt injection — mirrors <c>recentTextContext(max:)</c>.</summary>
    public string? RecentTextContext(int max = 3)
    {
        List<ClipboardItem> textItems;
        lock (_gate)
        {
            textItems = _history
                .Where(i => i.Kind is ClipboardItemKind.Text or ClipboardItemKind.Url or ClipboardItemKind.Code)
                .Take(max)
                .ToList();
        }
        if (textItems.Count == 0) return null;

        var lines = textItems.Select((item, i) =>
        {
            var preview = (item.Text ?? "");
            if (preview.Length > 200) preview = preview[..200];
            return $"[{i + 1}] {preview}";
        });
        return "Recent clipboard:\n" + string.Join("\n", lines);
    }

    private static string Hash(string text)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(text));
        return Convert.ToHexString(bytes);
    }

    private void Persist()
    {
        List<ClipboardItem> snapshot;
        lock (_gate) snapshot = _history.ToList();
        try
        {
            var json = JsonConvert.SerializeObject(snapshot);
            File.WriteAllText(LocalAppData.PathFor(FileName), json);
        }
        catch
        {
            // Best-effort persistence -- a failed write shouldn't crash clipboard tracking.
        }
    }

    private void Load()
    {
        try
        {
            var path = LocalAppData.PathFor(FileName);
            if (!File.Exists(path)) return;
            var items = JsonConvert.DeserializeObject<List<ClipboardItem>>(File.ReadAllText(path));
            if (items is not null) _history.AddRange(items);
        }
        catch
        {
            // Corrupt/missing history file -- start fresh rather than throwing on construction.
        }
    }
}
