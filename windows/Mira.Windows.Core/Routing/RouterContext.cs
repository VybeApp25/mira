namespace Mira.Windows.Core.Routing;

/// <summary>Mirrors macOS's <c>RouterContext</c> (Mira/Services/RouterService.swift) — the subset used by the ported classifier.</summary>
public sealed record RouterContext(string? RecentTranscript = null, int RecentMessageCount = 0);
