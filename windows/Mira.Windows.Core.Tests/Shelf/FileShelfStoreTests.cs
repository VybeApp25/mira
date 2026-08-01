using Mira.Windows.Core.Shelf;
using Xunit;

namespace Mira.Windows.Core.Tests.Shelf;

/// <summary>Tests the pure DisambiguateName logic directly against a fake "exists" predicate, so tests never touch the real Documents\Shelf folder on this machine.</summary>
public class FileShelfStoreTests
{
    [Fact]
    public void DisambiguateName_NoCollision_ReturnsOriginalName()
    {
        var result = FileShelfStore.DisambiguateName("report.pdf", _ => false);
        Assert.Equal("report.pdf", result);
    }

    [Fact]
    public void DisambiguateName_OneCollision_AppendsTwo()
    {
        var existing = new HashSet<string> { "report.pdf" };
        var result = FileShelfStore.DisambiguateName("report.pdf", existing.Contains);
        Assert.Equal("report 2.pdf", result);
    }

    [Fact]
    public void DisambiguateName_MultipleCollisions_SkipsToFirstFreeNumber()
    {
        var existing = new HashSet<string> { "report.pdf", "report 2.pdf", "report 3.pdf" };
        var result = FileShelfStore.DisambiguateName("report.pdf", existing.Contains);
        Assert.Equal("report 4.pdf", result);
    }

    [Fact]
    public void DisambiguateName_NoExtension_StillDisambiguates()
    {
        var existing = new HashSet<string> { "README" };
        var result = FileShelfStore.DisambiguateName("README", existing.Contains);
        Assert.Equal("README 2", result);
    }
}
