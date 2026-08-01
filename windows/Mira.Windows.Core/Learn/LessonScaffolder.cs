namespace Mira.Windows.Core.Learn;

/// <summary>
/// The Windows equivalent of the zero-LLM half of Mira/Services/LessonScaffolder.swift
/// -- a fixed 3-step skeleton for any app, no Claude call. The goal-authored
/// half lives in <see cref="LessonAuthor"/>; the YouTube-tutorial-authored
/// half is not ported this pass (see docs/windows/IMPLEMENTATION_PLAN.md).
/// </summary>
public static class LessonScaffolder
{
    /// <summary>Pure -- no I/O, directly testable.</summary>
    public static Lesson BuildTemplate(string appDisplayName, string? processName)
    {
        var openStepCheck = string.IsNullOrWhiteSpace(processName)
            ? LessonCheck.UserConfirmation()
            : LessonCheck.AppFrontmost(processName.Trim());

        return new Lesson
        {
            Id = Guid.NewGuid().ToString(),
            Title = $"Get started with {appDisplayName}",
            Description = $"A basic walkthrough of {appDisplayName}.",
            DomainApp = appDisplayName,
            IsBuiltin = false,
            Steps =
            [
                new LessonStep { Instruction = $"Open {appDisplayName}.", Check = openStepCheck },
                new LessonStep { Instruction = "Find the main toolbar or menu.", Check = LessonCheck.UserConfirmation() },
                new LessonStep { Instruction = "Try the task you wanted to do.", Check = LessonCheck.UserConfirmation() },
            ],
        };
    }
}
