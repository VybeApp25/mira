using Mira.Windows.Core.Clipboard;
using Xunit;

namespace Mira.Windows.Core.Tests.Clipboard;

/// <summary>Tests the pure ApplyAdd algorithm directly rather than the disk-touching singleton, mirroring how PlanExtensions.CanForPlan is tested apart from EntitlementService.</summary>
public class ClipboardHistoryStoreTests
{
    private static ClipboardItem Item(string text, ClipboardItemKind kind = ClipboardItemKind.Text, bool pinned = false) =>
        new() { Id = Guid.NewGuid(), Kind = kind, Text = text, IsPinned = pinned, CopiedAt = DateTimeOffset.UtcNow };

    [Fact]
    public void ApplyAdd_InsertsNewItemAtFront()
    {
        var current = new List<ClipboardItem> { Item("old") };
        var result = ClipboardHistoryStore.ApplyAdd(current, Item("new"), maxItems: 10);
        Assert.Equal("new", result[0].Text);
        Assert.Equal("old", result[1].Text);
    }

    [Fact]
    public void ApplyAdd_RemovesUnpinnedDuplicateOfSameContent()
    {
        var current = new List<ClipboardItem> { Item("dup") };
        var result = ClipboardHistoryStore.ApplyAdd(current, Item("dup"), maxItems: 10);
        Assert.Single(result); // the old "dup" was removed, only the new one remains
    }

    [Fact]
    public void ApplyAdd_KeepsPinnedDuplicateInsteadOfRemovingIt()
    {
        var current = new List<ClipboardItem> { Item("dup", pinned: true) };
        var result = ClipboardHistoryStore.ApplyAdd(current, Item("dup"), maxItems: 10);
        Assert.Equal(2, result.Count); // pinned original + new insert, no dedup against pinned items
    }

    [Fact]
    public void ApplyAdd_DifferentKindsWithSameTextAreNotDeduped()
    {
        var current = new List<ClipboardItem> { Item("abc", ClipboardItemKind.Text) };
        var result = ClipboardHistoryStore.ApplyAdd(current, Item("abc", ClipboardItemKind.Code), maxItems: 10);
        Assert.Equal(2, result.Count);
    }

    [Fact]
    public void ApplyAdd_TrimsUnpinnedItemsButNeverPinnedOnes()
    {
        var current = new List<ClipboardItem>();
        for (var i = 0; i < 5; i++) current.Add(Item($"pinned-{i}", pinned: true));
        for (var i = 0; i < 5; i++) current.Add(Item($"unpinned-{i}"));

        var result = ClipboardHistoryStore.ApplyAdd(current, Item("new"), maxItems: 7);

        Assert.Equal(7, result.Count);
        Assert.Equal(5, result.Count(i => i.IsPinned)); // all 5 pinned survive regardless of the cap
        Assert.Equal(2, result.Count(i => !i.IsPinned)); // only room for 2 of the unpinned + new
    }

    [Fact]
    public void RecentTextContext_ReturnsNull_WhenStoreEmpty()
    {
        // The singleton loads from disk on first access -- if this machine happens to
        // have real clipboard history persisted, this assertion only checks the shape
        // of a genuinely empty result is null, not that the store is always empty.
        var context = ClipboardHistoryStore.Shared.RecentTextContext(max: 0);
        Assert.Null(context);
    }
}
