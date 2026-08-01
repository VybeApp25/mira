namespace Mira.Windows.Core.Learn;

/// <summary>
/// The one seeded built-in lesson, mirroring <c>SkillCatalog</c>'s own
/// single built-in ("Turn on Dark Mode"). Re-pointed at real Windows
/// mechanics rather than a straight text port: the Settings app's actual
/// process name and the real dark-mode registry key, so every step in this
/// lesson is genuinely, deterministically checkable end to end -- not just
/// plausible-sounding instruction text.
/// </summary>
public static class LessonCatalog
{
    public static Lesson DarkModeBuiltin => new()
    {
        Id = "builtin-dark-mode",
        Title = "Turn on Dark Mode",
        Description = "Switch Windows to a dark color scheme.",
        DomainApp = "Settings",
        IsBuiltin = true,
        Steps =
        [
            new LessonStep
            {
                Instruction = "Open Windows Settings.",
                Check = LessonCheck.AppFrontmost("SystemSettings"),
                Remediation = "Press Win+I to open Settings.",
            },
            new LessonStep
            {
                Instruction = "Go to Personalization, then Colors.",
                Check = LessonCheck.UserConfirmation(),
                Remediation = "Personalization is in the left sidebar; Colors is one of its pages.",
            },
            new LessonStep
            {
                Instruction = "Under \"Choose your mode\", select Dark.",
                Check = LessonCheck.DarkModeEnabled(),
                Remediation = "It's a dropdown near the top of the Colors page.",
            },
        ],
    };

    public static IReadOnlyList<Lesson> Builtins => [DarkModeBuiltin];
}
