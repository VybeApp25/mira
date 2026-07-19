namespace Mira.Windows.Core.Crons;

public enum CronScheduleKind { Hourly, Daily, Weekly, Custom }

/// <summary>
/// The Windows equivalent of Mira/Models/CronModels.swift's <c>CronSchedule</c>
/// enum. Swift models this as a case-with-associated-values enum; C# has no
/// direct equivalent, so this is a single class with a <see cref="Kind"/>
/// discriminator and only the fields each kind actually uses populated —
/// mirrors how <see cref="Agents.AgentJob"/> already handles the same
/// Swift-enum-with-payload shape.
/// </summary>
public sealed class CronSchedule
{
    private static readonly string[] WeekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

    public CronScheduleKind Kind { get; set; }
    public int Hour { get; set; }
    public int Minute { get; set; }

    /// <summary>1=Sun...7=Sat, matching Foundation's <c>Calendar.weekday</c> that the Mac source keys off.</summary>
    public int Weekday { get; set; } = 1;

    public int IntervalMinutes { get; set; } = 30;

    public static CronSchedule Hourly() => new() { Kind = CronScheduleKind.Hourly };
    public static CronSchedule Daily(int hour, int minute) => new() { Kind = CronScheduleKind.Daily, Hour = hour, Minute = minute };
    public static CronSchedule Weekly(int weekday, int hour, int minute) => new() { Kind = CronScheduleKind.Weekly, Weekday = weekday, Hour = hour, Minute = minute };
    public static CronSchedule Custom(int intervalMinutes) => new() { Kind = CronScheduleKind.Custom, IntervalMinutes = Math.Max(1, intervalMinutes) };

    public string DisplayName => Kind switch
    {
        CronScheduleKind.Hourly => "Hourly",
        CronScheduleKind.Daily => $"Daily at {Hour:D2}:{Minute:D2}",
        CronScheduleKind.Weekly => $"Every {WeekdayNames[Math.Clamp(Weekday, 1, 7) - 1]} at {Hour:D2}:{Minute:D2}",
        CronScheduleKind.Custom => $"Every {IntervalMinutes}m",
        _ => "",
    };

    /// <summary>Pure — takes "now" as a parameter rather than reading the real clock, so it's directly unit-testable. Mirrors <c>CronSchedule.nextFire(after:)</c>.</summary>
    public DateTimeOffset NextFire(DateTimeOffset after) => Kind switch
    {
        CronScheduleKind.Hourly => after.AddHours(1),
        CronScheduleKind.Daily => NextDaily(after),
        CronScheduleKind.Weekly => NextWeekly(after),
        CronScheduleKind.Custom => after.AddMinutes(Math.Max(1, IntervalMinutes)),
        _ => after,
    };

    private DateTimeOffset NextDaily(DateTimeOffset after)
    {
        var today = new DateTimeOffset(after.Year, after.Month, after.Day, Hour, Minute, 0, after.Offset);
        return today > after ? today : today.AddDays(1);
    }

    private DateTimeOffset NextWeekly(DateTimeOffset after)
    {
        var currentWeekday = (int)after.DayOfWeek + 1; // .NET Sunday=0 -> Foundation Sunday=1
        var daysAhead = ((Weekday - currentWeekday) + 7) % 7;
        var baseDate = after.Date.AddDays(daysAhead);
        var fire = new DateTimeOffset(baseDate.Year, baseDate.Month, baseDate.Day, Hour, Minute, 0, after.Offset);
        return fire > after ? fire : fire.AddDays(7);
    }
}
