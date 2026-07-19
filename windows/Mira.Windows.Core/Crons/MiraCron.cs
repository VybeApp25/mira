namespace Mira.Windows.Core.Crons;

/// <summary>Mirrors Mira/Models/CronModels.swift's <c>MiraCron</c> struct — a recurring background task that fires a prompt into Claude on a schedule.</summary>
public sealed class MiraCron
{
    public required Guid Id { get; init; }
    public required string Name { get; set; }
    public required string Prompt { get; set; }
    public required CronSchedule Schedule { get; set; }
    public bool Enabled { get; set; } = true;
    public DateTimeOffset? LastRunAt { get; set; }
    public string? LastRunResult { get; set; }
    public DateTimeOffset NextFireAt { get; set; }

    public static MiraCron Create(string name, string prompt, CronSchedule schedule, DateTimeOffset now)
    {
        return new MiraCron
        {
            Id = Guid.NewGuid(),
            Name = name,
            Prompt = prompt,
            Schedule = schedule,
            Enabled = true,
            NextFireAt = schedule.NextFire(now),
        };
    }
}
