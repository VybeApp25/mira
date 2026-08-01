namespace Mira.Windows.Core.Agents;

/// <summary>
/// The Windows equivalent of the reachable subset of Mira/Models/AgentJob.swift's
/// <c>AgentJobStatus</c> — trimmed to the states this port's job types (see
/// <see cref="AgentJobType"/>) can actually reach. The full Mac enum also has
/// Preparing/Reading/Writing sub-stages and WaitingForInput/WaitingForConfirmation/
/// WaitingForVariantSelection/BlockedPermission/BlockedTool gates, all driven by
/// the WebsiteBuilder/Improvement/Publish agents this pass deliberately defers —
/// none of DeepResearch/ContentGeneration/Generic's real Mac runners ever call
/// those gates, so building UI for them here would be speculative, not faithful.
/// </summary>
public enum AgentJobStatus { Queued, Running, Completed, Failed, Cancelled }

/// <summary>
/// Mirrors Mira/Models/AgentJob.swift's <c>AgentJobType</c>, trimmed to the 3
/// types that actually have a real runner in this port (see
/// docs/windows/IMPLEMENTATION_PLAN.md's Agents-tab section for why
/// WebsiteBuilder and its whole family are deferred rather than declared and
/// left to silently fall back to a generic completion the way unwired types
/// do on the Mac original).
/// </summary>
public enum AgentJobType { DeepResearch, ContentGeneration, Custom }

/// <summary>One agent job — mirrors the reachable fields of Mira/Models/AgentJob.swift's <c>AgentJob</c> struct.</summary>
public sealed class AgentJob
{
    public required Guid Id { get; init; }
    public required AgentJobType Type { get; init; }
    public required string Prompt { get; init; }
    public required DateTimeOffset CreatedAt { get; init; }
    public AgentJobStatus Status { get; set; } = AgentJobStatus.Queued;
    public string? ResultText { get; set; }
    public string? OutputFilePath { get; set; }
    public string? ErrorMessage { get; set; }

    public string TypeLabel => Type switch
    {
        AgentJobType.DeepResearch => "Research",
        AgentJobType.ContentGeneration => "Content",
        _ => "Task",
    };

    public string Icon => Type switch
    {
        AgentJobType.DeepResearch => "🔎",
        AgentJobType.ContentGeneration => "📝",
        _ => "🤖",
    };

    /// <summary>
    /// Client-side job-type guess from free text — ported from
    /// <c>AgentJobType.detect(from:)</c>, trimmed to the types this port
    /// actually runs (the Mac original also detects website-builder/app
    /// phrasing, which has no runner here — see the type comment above).
    /// </summary>
    public static AgentJobType Detect(string prompt)
    {
        var p = prompt.ToLowerInvariant();
        string[] researchSignals = ["research", "report on", "analyze", "investigate", "find out about", "look into", "deep dive"];
        string[] contentSignals = ["write", "draft", "article", "blog", "essay", "compose", "summary of", "summarize"];

        if (researchSignals.Any(p.Contains)) return AgentJobType.DeepResearch;
        if (contentSignals.Any(p.Contains)) return AgentJobType.ContentGeneration;
        return AgentJobType.Custom;
    }
}
