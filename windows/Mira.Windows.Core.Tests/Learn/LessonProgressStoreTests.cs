using Mira.Windows.Core.Learn;
using Xunit;

namespace Mira.Windows.Core.Tests.Learn;

/// <summary>Tests the pure mastery/review math directly, so tests never touch the live singleton's real on-disk progress state.</summary>
public class LessonProgressStoreTests
{
    [Theory]
    [InlineData(0, 0.0)]
    [InlineData(1, 0.55)]
    [InlineData(2, 0.7975)]
    [InlineData(3, 0.908875)]
    public void MasteryScore_MatchesExpectedCurve(int completions, double expected)
    {
        Assert.Equal(expected, LessonProgressStore.MasteryScore(completions), precision: 4);
    }

    [Fact]
    public void IsMastered_BelowThreshold_IsFalse()
    {
        Assert.False(LessonProgressStore.IsMastered(1)); // 0.55
        Assert.False(LessonProgressStore.IsMastered(2)); // 0.7975
    }

    [Fact]
    public void IsMastered_AtOrAboveThreshold_IsTrue()
    {
        Assert.True(LessonProgressStore.IsMastered(3)); // 0.8889
    }

    [Fact]
    public void IsReviewDue_NotMastered_IsFalseEvenIfStale()
    {
        var longAgo = DateTimeOffset.UtcNow.AddDays(-30);
        Assert.False(LessonProgressStore.IsReviewDue(completions: 1, lastCompletedAt: longAgo, now: DateTimeOffset.UtcNow));
    }

    [Fact]
    public void IsReviewDue_MasteredAndRecent_IsFalse()
    {
        var recent = DateTimeOffset.UtcNow.AddDays(-1);
        Assert.False(LessonProgressStore.IsReviewDue(completions: 3, lastCompletedAt: recent, now: DateTimeOffset.UtcNow));
    }

    [Fact]
    public void IsReviewDue_MasteredAndStale_IsTrue()
    {
        var stale = DateTimeOffset.UtcNow.AddDays(-8);
        Assert.True(LessonProgressStore.IsReviewDue(completions: 3, lastCompletedAt: stale, now: DateTimeOffset.UtcNow));
    }

    [Fact]
    public void IsReviewDue_MasteredButNeverCompleted_IsFalse()
    {
        Assert.False(LessonProgressStore.IsReviewDue(completions: 3, lastCompletedAt: null, now: DateTimeOffset.UtcNow));
    }
}
