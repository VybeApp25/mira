using Mira.Windows.Core.Clipboard;
using Xunit;

namespace Mira.Windows.Core.Tests.Clipboard;

public class ClipboardItemTests
{
    [Theory]
    [InlineData("https://example.com", ClipboardItemKind.Url)]
    [InlineData("http://example.com", ClipboardItemKind.Url)]
    [InlineData("ftp://example.com/file", ClipboardItemKind.Url)]
    [InlineData("#fff", ClipboardItemKind.Color)]
    [InlineData("#ffffff", ClipboardItemKind.Color)]
    [InlineData("#ffffffff", ClipboardItemKind.Color)]
    [InlineData("rgb(255,255,255)", ClipboardItemKind.Color)]
    [InlineData("rgba(255,255,255,1)", ClipboardItemKind.Color)]
    [InlineData("hsl(0,0%,100%)", ClipboardItemKind.Color)]
    [InlineData("plain text", ClipboardItemKind.Text)]
    [InlineData("#notacolor-too-long-to-be-hex", ClipboardItemKind.Text)]
    public void Classify_MatchesExpectedKind(string text, ClipboardItemKind expected)
        => Assert.Equal(expected, ClipboardItem.Classify(text));

    [Fact]
    public void Classify_MultilineWithCodeSignal_IsCode()
    {
        var code = "function foo() {\n  return 1;\n}\n";
        Assert.Equal(ClipboardItemKind.Code, ClipboardItem.Classify(code));
    }

    [Fact]
    public void Classify_MultilinePlainText_IsNotCode()
    {
        var text = "line one\nline two\nline three\nline four";
        Assert.Equal(ClipboardItemKind.Text, ClipboardItem.Classify(text));
    }

    [Fact]
    public void DisplayTitle_TruncatesLongText()
    {
        var item = new ClipboardItem { Id = Guid.NewGuid(), Kind = ClipboardItemKind.Text, Text = new string('a', 200), CopiedAt = DateTimeOffset.UtcNow };
        Assert.Equal(80, item.DisplayTitle.Length);
    }

    [Fact]
    public void DisplayTitle_File_UsesFileName()
    {
        var item = new ClipboardItem { Id = Guid.NewGuid(), Kind = ClipboardItemKind.File, FilePaths = ["C:\\Users\\me\\report.pdf"], CopiedAt = DateTimeOffset.UtcNow };
        Assert.Equal("report.pdf", item.DisplayTitle);
    }
}
