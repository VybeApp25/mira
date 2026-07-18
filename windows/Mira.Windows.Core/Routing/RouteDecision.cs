namespace Mira.Windows.Core.Routing;

/// <summary>
/// Mirrors macOS's <c>RouteDecision</c> (Mira/Services/RouterService.swift),
/// trimmed to what this milestone's dispatch actually uses. The full Swift
/// struct also carries a multi-step <c>ClarificationSpec</c> wizard (a
/// question/answer flow with typed steps) for routes like website-builder —
/// deliberately simplified here to a single <see cref="ClarificationQuestion"/>
/// string, since the wizard UI itself is out of scope for this milestone and
/// nothing on Windows yet consumes the structured form.
/// </summary>
public sealed record RouteDecision(
    MiraRoute Route,
    double Confidence,
    string Explanation,
    string? ConfirmationSummary = null,
    string? ClarificationQuestion = null,
    bool IsDangerous = false
);
