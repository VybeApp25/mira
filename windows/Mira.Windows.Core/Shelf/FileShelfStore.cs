using Mira.Windows.Core.Entitlements;

namespace Mira.Windows.Core.Shelf;

/// <summary>
/// The Windows equivalent of Mira/Services/FileShelf.swift's FileShelfService —
/// a temporary drag-and-drop file staging area, NOT a knowledge/memory system
/// (confirmed by reading the real source: no AI/Claude call anywhere in that
/// file). Dropped files are physically copied into %UserProfile%\Documents\Shelf,
/// the direct equivalent of Mac's own ~/Documents/Shelf — a real, Explorer-visible
/// folder, not a hidden AppData store — so the shelf survives relaunches and can
/// also just be opened directly. AirDrop (Mac's Ultra-tier "send" action) has no
/// Windows equivalent and is deliberately not ported.
/// </summary>
public sealed class FileShelfStore
{
    public static FileShelfStore Shared { get; } = new();

    public const int ProLimit = 5;

    private readonly List<string> _items = new();
    private readonly object _lock = new();

    public event Action? Changed;

    private FileShelfStore() => LoadExisting();

    public static string ShelfDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Shelf");

    public IReadOnlyList<string> Items { get { lock (_lock) return _items.ToList(); } }

    public int Limit => EntitlementService.Shared.Plan.MaxShelfItems();

    public bool AtLimit { get { lock (_lock) return _items.Count >= Limit; } }

    /// <summary>Copies each source path into the shelf directory, stopping once the plan's item limit is reached — mirrors <c>FileShelfService.add(_:)</c>.</summary>
    public void Add(IEnumerable<string> paths)
    {
        Directory.CreateDirectory(ShelfDirectory);
        foreach (var src in paths)
        {
            lock (_lock) { if (_items.Count >= Limit) break; }
            var dest = CopyIntoShelf(src);
            if (dest is null) continue;
            lock (_lock) { if (!_items.Contains(dest)) _items.Add(dest); }
        }
        Changed?.Invoke();
    }

    public void Remove(string path)
    {
        if (path.StartsWith(ShelfDirectory, StringComparison.OrdinalIgnoreCase))
        {
            try { File.Delete(path); } catch { /* best-effort */ }
        }
        lock (_lock) _items.Remove(path);
        Changed?.Invoke();
    }

    public void Clear()
    {
        lock (_lock)
        {
            foreach (var path in _items.Where(p => p.StartsWith(ShelfDirectory, StringComparison.OrdinalIgnoreCase)))
            {
                try { File.Delete(path); } catch { /* best-effort */ }
            }
            _items.Clear();
        }
        Changed?.Invoke();
    }

    public void OpenShelfFolder()
    {
        Directory.CreateDirectory(ShelfDirectory);
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(ShelfDirectory) { UseShellExecute = true });
    }

    private string? CopyIntoShelf(string src)
    {
        try
        {
            var dest = Path.Combine(ShelfDirectory, DisambiguateName(Path.GetFileName(src), n => File.Exists(Path.Combine(ShelfDirectory, n))));
            File.Copy(src, dest);
            return dest;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// The pure collision-disambiguation logic, extracted so it's directly
    /// unit-testable against a fake "does this name already exist" predicate
    /// instead of the real filesystem — same "extract for testability" pattern
    /// as <see cref="Agents.AgentJobStore.CheckCanSubmit"/> and
    /// <see cref="Skills.SkillStore.BuildContextFrom"/>. Mirrors
    /// <c>FileShelfService.uniqueDestination(for:)</c>: "name.ext", then
    /// "name 2.ext", "name 3.ext", etc.
    /// </summary>
    public static string DisambiguateName(string name, Func<string, bool> exists)
    {
        if (!exists(name)) return name;

        var baseName = Path.GetFileNameWithoutExtension(name);
        var ext = Path.GetExtension(name);
        var n = 2;
        string candidate;
        do
        {
            candidate = $"{baseName} {n}{ext}";
            n++;
        } while (exists(candidate));
        return candidate;
    }

    private void LoadExisting()
    {
        if (!Directory.Exists(ShelfDirectory)) return;
        try
        {
            var files = Directory.GetFiles(ShelfDirectory).OrderBy(File.GetLastWriteTimeUtc).ToList();
            _items.AddRange(files);
        }
        catch { /* best-effort — an empty shelf is a safe fallback */ }
    }
}
