using Mira.Windows.Core.Crons;
using Xunit;

namespace Mira.Windows.Core.Tests.Crons;

/// <summary>Pins CronSchedule.NextFire's date math against hand-computed expectations, since it's a from-scratch reimplementation of CronSchedule.swift's Foundation Calendar-based logic, not a direct API port.</summary>
public class CronScheduleTests
{
    private static readonly DateTimeOffset Wed_10_00 = new(2026, 7, 15, 10, 0, 0, TimeSpan.Zero); // a Wednesday

    [Fact]
    public void Hourly_AddsOneHour()
    {
        var next = CronSchedule.Hourly().NextFire(Wed_10_00);
        Assert.Equal(Wed_10_00.AddHours(1), next);
    }

    [Fact]
    public void Daily_TimeLaterToday_FiresToday()
    {
        var schedule = CronSchedule.Daily(hour: 15, minute: 30);
        var next = schedule.NextFire(Wed_10_00);
        Assert.Equal(new DateTimeOffset(2026, 7, 15, 15, 30, 0, TimeSpan.Zero), next);
    }

    [Fact]
    public void Daily_TimeAlreadyPassedToday_FiresTomorrow()
    {
        var schedule = CronSchedule.Daily(hour: 9, minute: 0);
        var next = schedule.NextFire(Wed_10_00);
        Assert.Equal(new DateTimeOffset(2026, 7, 16, 9, 0, 0, TimeSpan.Zero), next);
    }

    [Fact]
    public void Weekly_TargetDayLaterThisWeek_FiresThisWeek()
    {
        // Wed_10_00 is a Wednesday (weekday=4); target Friday (weekday=6).
        var schedule = CronSchedule.Weekly(weekday: 6, hour: 9, minute: 0);
        var next = schedule.NextFire(Wed_10_00);
        Assert.Equal(new DateTimeOffset(2026, 7, 17, 9, 0, 0, TimeSpan.Zero), next); // that Friday
    }

    [Fact]
    public void Weekly_TargetDayIsTodayButTimePassed_FiresNextWeek()
    {
        // Wed_10_00 is Wednesday at 10:00; ask for Wednesday at 09:00 (already passed today).
        var schedule = CronSchedule.Weekly(weekday: 4, hour: 9, minute: 0);
        var next = schedule.NextFire(Wed_10_00);
        Assert.Equal(new DateTimeOffset(2026, 7, 22, 9, 0, 0, TimeSpan.Zero), next); // the following Wednesday
    }

    [Fact]
    public void Weekly_TargetDayIsTodayButTimeNotYetPassed_FiresToday()
    {
        var schedule = CronSchedule.Weekly(weekday: 4, hour: 18, minute: 0);
        var next = schedule.NextFire(Wed_10_00);
        Assert.Equal(new DateTimeOffset(2026, 7, 15, 18, 0, 0, TimeSpan.Zero), next);
    }

    [Fact]
    public void Weekly_TargetDayEarlierInWeek_WrapsToNextWeek()
    {
        // Target Monday (weekday=2) from a Wednesday.
        var schedule = CronSchedule.Weekly(weekday: 2, hour: 9, minute: 0);
        var next = schedule.NextFire(Wed_10_00);
        Assert.Equal(new DateTimeOffset(2026, 7, 20, 9, 0, 0, TimeSpan.Zero), next); // the following Monday
    }

    [Fact]
    public void Custom_AddsIntervalMinutes()
    {
        var schedule = CronSchedule.Custom(45);
        var next = schedule.NextFire(Wed_10_00);
        Assert.Equal(Wed_10_00.AddMinutes(45), next);
    }

    [Fact]
    public void Custom_ClampsToAtLeastOneMinute()
    {
        var schedule = CronSchedule.Custom(0);
        Assert.Equal(1, schedule.IntervalMinutes);
    }

    [Theory]
    [InlineData(CronScheduleKind.Hourly, "Hourly")]
    public void DisplayName_Hourly(CronScheduleKind kind, string expected)
    {
        var schedule = new CronSchedule { Kind = kind };
        Assert.Equal(expected, schedule.DisplayName);
    }

    [Fact]
    public void DisplayName_Daily_FormatsWithLeadingZeros()
    {
        var schedule = CronSchedule.Daily(9, 5);
        Assert.Equal("Daily at 09:05", schedule.DisplayName);
    }

    [Fact]
    public void DisplayName_Weekly_NamesTheDay()
    {
        var schedule = CronSchedule.Weekly(weekday: 6, hour: 9, minute: 0); // Fri
        Assert.Equal("Every Fri at 09:00", schedule.DisplayName);
    }

    [Fact]
    public void DisplayName_Custom_ShowsMinutes()
    {
        var schedule = CronSchedule.Custom(30);
        Assert.Equal("Every 30m", schedule.DisplayName);
    }
}
