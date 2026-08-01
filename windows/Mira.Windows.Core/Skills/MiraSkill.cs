namespace Mira.Windows.Core.Skills;

/// <summary>Mirrors Mac's built-in vs. platform vs. user distinction, collapsed to two since Windows has no bundled "platform" SKILL.md folder set to mirror in this pass.</summary>
public enum MiraSkillOrigin { Builtin, User }

/// <summary>
/// The Windows equivalent of Mira/Models/MiraSkill.swift — a "skill" here is
/// plain text, not code: <see cref="Context"/> is spliced verbatim into the
/// chat system prompt when the skill is toggled on (see
/// <see cref="SkillStore.BuildContext"/>). It has no ability to execute
/// anything on its own — see docs/windows/IMPLEMENTATION_PLAN.md's Skills
/// section for why that fact (confirmed by reading the real Mac source, not
/// assumed) is exactly what makes this safe to port as-is on Windows today.
/// </summary>
public sealed class MiraSkill
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required string Tagline { get; init; }
    public required string Icon { get; init; }
    public required string Category { get; init; }
    public required string Context { get; init; }
    public required MiraSkillOrigin Origin { get; init; }
}
