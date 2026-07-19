using Xunit;
using MemoryModel = Mira.Windows.Core.Memory.Memory;
using MemoryConfidenceTier = Mira.Windows.Core.Memory.MemoryConfidenceTier;
using MemoryStore = Mira.Windows.Core.Memory.MemoryStore;

namespace Mira.Windows.Core.Tests.Memory;

/// <summary>Tests the pure confidence/decay/formatting math directly, so tests never touch the live singleton's real on-disk memory state.</summary>
public class MemoryStoreTests
{
    [Fact]
    public void ComputeReinforcedConfidence_BoostsByPoint08()
    {
        Assert.Equal(0.58, MemoryStore.ComputeReinforcedConfidence(0.50, 0.50), precision: 4);
    }

    [Fact]
    public void ComputeReinforcedConfidence_ProposedHigherThanBoosted_UsesProposed()
    {
        // existing 0.50 + 0.08 = 0.58, but a fresh explicit restatement proposes 0.95 -- higher wins.
        Assert.Equal(0.95, MemoryStore.ComputeReinforcedConfidence(0.50, 0.95), precision: 4);
    }

    [Fact]
    public void ComputeReinforcedConfidence_CapsAtOne()
    {
        Assert.Equal(1.0, MemoryStore.ComputeReinforcedConfidence(0.97, 0.97), precision: 4);
    }

    [Fact]
    public void ComputeDecayedConfidence_NoDaysPassed_Unchanged()
    {
        Assert.Equal(0.90, MemoryStore.ComputeDecayedConfidence(0.90, 0), precision: 4);
    }

    [Fact]
    public void ComputeDecayedConfidence_TenDays_DecaysByPoint10()
    {
        Assert.Equal(0.80, MemoryStore.ComputeDecayedConfidence(0.90, 10), precision: 4);
    }

    [Fact]
    public void ComputeDecayedConfidence_NeverGoesBelowFloor()
    {
        Assert.Equal(0.10, MemoryStore.ComputeDecayedConfidence(0.15, 100), precision: 4);
    }

    [Fact]
    public void ComputeDecayedConfidence_SubMillidayGap_NoChange()
    {
        // 0.05 days * 0.01/day = 0.0005 decay -- below the 0.001 "did anything really change" threshold.
        Assert.Equal(0.90, MemoryStore.ComputeDecayedConfidence(0.90, 0.05), precision: 4);
    }

    private static MemoryModel Mem(string key, string value, double confidence) => new()
    {
        Id = Guid.NewGuid(),
        Key = key,
        Value = value,
        Confidence = confidence,
        CreatedAt = DateTimeOffset.UtcNow,
        UpdatedAt = DateTimeOffset.UtcNow,
    };

    [Fact]
    public void FormatPromptBlock_Empty_ReturnsEmptyString()
    {
        Assert.Equal("", MemoryStore.FormatPromptBlock([]));
    }

    [Fact]
    public void FormatPromptBlock_HighConfidence_NoQualifier()
    {
        var text = MemoryStore.FormatPromptBlock([Mem("favorite_color", "blue", 0.95)]);
        Assert.Equal("[What I know about you]\nfavorite_color: blue", text);
    }

    [Fact]
    public void FormatPromptBlock_MediumConfidence_AddsProbablyQualifier()
    {
        var text = MemoryStore.FormatPromptBlock([Mem("preferred_editor", "VS Code", 0.6)]);
        Assert.Contains("preferred_editor: VS Code (probably)", text);
    }

    [Fact]
    public void FormatPromptBlock_LowConfidence_AddsUncertainQualifier()
    {
        var text = MemoryStore.FormatPromptBlock([Mem("timezone", "PST", 0.3)]);
        Assert.Contains("timezone: PST (uncertain)", text);
    }

    [Fact]
    public void FormatPromptBlock_MultipleMemories_OneLineEach()
    {
        var text = MemoryStore.FormatPromptBlock([Mem("a", "1", 0.9), Mem("b", "2", 0.9)]);
        Assert.Equal("[What I know about you]\na: 1\nb: 2", text);
    }

    [Theory]
    [InlineData(0.95, MemoryConfidenceTier.High)]
    [InlineData(0.8, MemoryConfidenceTier.High)]
    [InlineData(0.6, MemoryConfidenceTier.Medium)]
    [InlineData(0.5, MemoryConfidenceTier.Medium)]
    [InlineData(0.3, MemoryConfidenceTier.Low)]
    public void ConfidenceTier_MatchesSwiftThresholds(double confidence, MemoryConfidenceTier expected)
    {
        var mem = Mem("k", "v", confidence);
        Assert.Equal(expected, mem.ConfidenceTier);
    }
}
