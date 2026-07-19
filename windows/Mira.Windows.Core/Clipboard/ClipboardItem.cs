namespace Mira.Windows.Core.Clipboard;

/// <summary>The Windows equivalent of Mira/Models/ClipboardItem.swift.</summary>
public enum ClipboardItemKind { Text, Url, Code, Color, Image, File }

/// <summary>
/// One clipboard history entry. <c>ImagePng</c> holds a PNG thumbnail (mirrors
/// the Mac original's 400px-side thumbnail) rather than a WPF/GDI bitmap type,
/// since this class has no UI-framework reference — the App layer decodes it
/// for display.
/// </summary>
public sealed class ClipboardItem
{
    public required Guid Id { get; init; }
    public required ClipboardItemKind Kind { get; init; }
    public string? Text { get; init; }
    public byte[]? ImagePng { get; init; }
    public IReadOnlyList<string>? FilePaths { get; init; }
    public string? SourceApp { get; init; }
    public required DateTimeOffset CopiedAt { get; init; }
    public bool IsPinned { get; set; }
    public string? Label { get; set; }

    /// <summary>Human-readable title shown in the history list — mirrors <c>displayTitle</c>.</summary>
    public string DisplayTitle => Kind switch
    {
        ClipboardItemKind.Text => string.IsNullOrEmpty(Text) ? "Text" : Truncate(Text, 80),
        ClipboardItemKind.Url => Text ?? "URL",
        ClipboardItemKind.Code => string.IsNullOrEmpty(Text) ? "Code" : Truncate(Text, 80),
        ClipboardItemKind.Color => Text ?? "Color",
        ClipboardItemKind.Image => "Image",
        ClipboardItemKind.File => FilePaths is { Count: > 0 } ? Path.GetFileName(FilePaths[0]) : "File",
        _ => "Clip",
    };

    /// <summary>Preview snippet for the detail row — mirrors <c>snippet</c>.</summary>
    public string? Snippet => Kind switch
    {
        ClipboardItemKind.Text or ClipboardItemKind.Url or ClipboardItemKind.Code or ClipboardItemKind.Color =>
            Text is { Length: > 80 } ? Truncate(Text, 200) + "…" : null,
        ClipboardItemKind.File => FilePaths is null ? null : string.Join(", ", FilePaths.Select(Path.GetFileName)),
        _ => null,
    };

    public string Icon => Kind switch
    {
        ClipboardItemKind.Text => "📄",
        ClipboardItemKind.Url => "🔗",
        ClipboardItemKind.Code => "🖥",
        ClipboardItemKind.Image => "🖼",
        ClipboardItemKind.Color => "🎨",
        ClipboardItemKind.File => "📁",
        _ => "📋",
    };

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max];

    /// <summary>
    /// Classifies free text into a kind — ported 1:1 from
    /// <c>ClipboardMonitorService.classify(_:)</c>, same prefixes/signals.
    /// </summary>
    public static ClipboardItemKind Classify(string text)
    {
        var t = text.Trim();
        if (t.StartsWith("http://") || t.StartsWith("https://") || t.StartsWith("ftp://")) return ClipboardItemKind.Url;
        if (t.StartsWith('#') && (t.Length == 4 || t.Length == 7 || t.Length == 9)) return ClipboardItemKind.Color;
        if (t.StartsWith("rgb(") || t.StartsWith("rgba(") || t.StartsWith("hsl(")) return ClipboardItemKind.Color;

        string[] codeSignals = ["{", "}", "=>", "->", "func ", "def ", "class ", "import ", "const ", "var ", "let "];
        var newlines = t.Split('\n').Length;
        if (newlines > 2 && codeSignals.Any(t.Contains)) return ClipboardItemKind.Code;

        return ClipboardItemKind.Text;
    }
}
