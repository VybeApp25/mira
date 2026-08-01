using Mira.Windows.Core.Crons;
using Xunit;

namespace Mira.Windows.Core.Tests.Crons;

/// <summary>Tests the pure ComputeDue filter directly, so tests never touch the live singleton's real on-disk cron list.</summary>
public class CronStoreTests
{
    private static MiraCron Cron(bool enabled, DateTimeOffset nextFireAt) => new()
    {
        Id = Guid.NewGuid(),
        Name = "test",
        Prompt = "prompt",
        Schedule = CronSchedule.Hourly(),
        Enabled = enabled,
        NextFireAt = nextFireAt,
    };

    [Fact]
    public void ComputeDue_EnabledAndPastDue_IsIncluded()
    {
        var now = DateTimeOffset.UtcNow;
        var cron = Cron(enabled: true, nextFireAt: now.AddMinutes(-1));
        var due = CronStore.ComputeDue([cron], now);
        Assert.Single(due);
    }

    [Fact]
    public void ComputeDue_EnabledAndExactlyNow_IsIncluded()
    {
        var now = DateTimeOffset.UtcNow;
        var cron = Cron(enabled: true, nextFireAt: now);
        var due = CronStore.ComputeDue([cron], now);
        Assert.Single(due);
    }

    [Fact]
    public void ComputeDue_NotYetDue_IsExcluded()
    {
        var now = DateTimeOffset.UtcNow;
        var cron = Cron(enabled: true, nextFireAt: now.AddMinutes(1));
        var due = CronStore.ComputeDue([cron], now);
        Assert.Empty(due);
    }

    [Fact]
    public void ComputeDue_DisabledEvenIfPastDue_IsExcluded()
    {
        var now = DateTimeOffset.UtcNow;
        var cron = Cron(enabled: false, nextFireAt: now.AddMinutes(-10));
        var due = CronStore.ComputeDue([cron], now);
        Assert.Empty(due);
    }

    [Fact]
    public void ComputeDue_MixedList_ReturnsOnlyDueEnabledOnes()
    {
        var now = DateTimeOffset.UtcNow;
        var dueEnabled = Cron(enabled: true, nextFireAt: now.AddMinutes(-5));
        var dueDisabled = Cron(enabled: false, nextFireAt: now.AddMinutes(-5));
        var notDue = Cron(enabled: true, nextFireAt: now.AddMinutes(5));

        var due = CronStore.ComputeDue([dueEnabled, dueDisabled, notDue], now);

        Assert.Single(due);
        Assert.Same(dueEnabled, due[0]);
    }
}
