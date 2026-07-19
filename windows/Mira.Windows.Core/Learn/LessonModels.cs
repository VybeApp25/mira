namespace Mira.Windows.Core.Learn;

/// <summary>
/// Mirrors the reachable subset of Mira/Models/TeachingModels.swift's <c>SuccessCheck</c>
/// enum. Trimmed to the three checks this port can verify without vision:
/// <c>.appFrontmost</c> and <c>.userConfirmation</c> port directly; <c>.darkModeEnabled</c>
/// is re-pointed at the Windows dark-mode registry key instead of
/// <c>UserDefaults</c>("AppleInterfaceStyle"). <c>.visualState</c> (a throttled
/// Claude vision call, see <c>VisionStateVerifier.swift</c>) is deliberately not
/// ported this pass -- see docs/windows/IMPLEMENTATION_PLAN.md's Learn section
/// for why, and note this port's own <c>Vision/GuidanceLocator.cs</c> is the
/// reusable building block a future pass would extend.
/// </summary>
public enum LessonCheckKind { AppFrontmost, DarkModeEnabled, UserConfirmation }

/// <summary>
/// Mirrors <c>SuccessCheck</c>'s associated values as a single class with a
/// <see cref="Kind"/> discriminator -- same shape decision already made for
/// <see cref="Agents.AgentJob"/> and <see cref="Crons.CronSchedule"/>.
/// </summary>
public sealed class LessonCheck
{
    public LessonCheckKind Kind { get; set; }

    /// <summary>Process name to match for <see cref="LessonCheckKind.AppFrontmost"/> (e.g. "notepad", case-insensitive); unused otherwise.</summary>
    public string? ProcessName { get; set; }

    public static LessonCheck AppFrontmost(string processName) => new() { Kind = LessonCheckKind.AppFrontmost, ProcessName = processName };
    public static LessonCheck DarkModeEnabled() => new() { Kind = LessonCheckKind.DarkModeEnabled };
    public static LessonCheck UserConfirmation() => new() { Kind = LessonCheckKind.UserConfirmation };

    /// <summary>True if this check can ever be satisfied by <see cref="LessonRunner"/>'s automatic polling rather than needing an explicit user tap.</summary>
    public bool IsObservable => Kind != LessonCheckKind.UserConfirmation;
}

/// <summary>Mirrors the reachable fields of <c>TeachingStep</c> -- <c>target</c>/annotation and <c>action</c> (autonomous-mode) are dropped, both belonging to the vision-grounding/autonomous-mode work this pass defers.</summary>
public sealed class LessonStep
{
    public required string Instruction { get; set; }
    public required LessonCheck Check { get; set; }
    public string? Remediation { get; set; }
}

/// <summary>Mirrors <c>TeachingSkill</c> -- a lesson's <c>grounding</c> tier and <c>tutorialURL</c> are dropped, both belonging to deferred work (vision grounding, YouTube-tutorial authoring).</summary>
public sealed class Lesson
{
    public required string Id { get; set; }
    public required string Title { get; set; }
    public required string Description { get; set; }

    /// <summary>Display name of the app this lesson teaches, e.g. "Notepad" -- shown in the UI, distinct from any step's <see cref="LessonCheck.ProcessName"/>.</summary>
    public required string DomainApp { get; set; }

    public required List<LessonStep> Steps { get; set; }

    /// <summary>True for the one seeded built-in ("Turn on Dark Mode") -- mirrors <c>SkillCatalog</c>'s seeded built-in, not user-deletable.</summary>
    public bool IsBuiltin { get; set; }
}
