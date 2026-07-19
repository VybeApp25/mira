namespace Mira.Windows.Core.Memory;

public enum MemoryCategory { Preference, Project, Person, Fact, Goal }

public enum MemorySource { Explicit, Observed }

public enum MemoryConfidenceTier { High, Medium, Low }

/// <summary>Mirrors Mira/Models/MemoryStore.swift's <c>Memory</c> struct exactly.</summary>
public sealed class Memory
{
    public required Guid Id { get; init; }
    public required string Key { get; set; }
    public required string Value { get; set; }
    public MemoryCategory Category { get; set; } = MemoryCategory.Fact;
    public MemorySource Source { get; set; } = MemorySource.Explicit;
    public double Confidence { get; set; } = 0.95;
    public string? Notes { get; set; }
    public required DateTimeOffset CreatedAt { get; init; }
    public DateTimeOffset UpdatedAt { get; set; }
    public int AccessCount { get; set; } = 1;

    public MemoryConfidenceTier ConfidenceTier =>
        Confidence >= 0.8 ? MemoryConfidenceTier.High :
        Confidence >= 0.5 ? MemoryConfidenceTier.Medium : MemoryConfidenceTier.Low;
}
