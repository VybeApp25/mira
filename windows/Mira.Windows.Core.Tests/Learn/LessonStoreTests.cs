using Mira.Windows.Core.Learn;
using Xunit;

namespace Mira.Windows.Core.Tests.Learn;

public class LessonStoreTests
{
    private static Lesson ValidLesson() => new()
    {
        Id = "test",
        Title = "Test Lesson",
        Description = "A test.",
        DomainApp = "TestApp",
        Steps = [new LessonStep { Instruction = "Do a thing.", Check = LessonCheck.UserConfirmation() }],
    };

    [Fact]
    public void Validate_WellFormedLesson_IsValid()
    {
        var (valid, reason) = LessonStore.Validate(ValidLesson());
        Assert.True(valid, reason);
    }

    [Fact]
    public void Validate_NoSteps_IsInvalid()
    {
        var lesson = ValidLesson();
        lesson.Steps = [];
        var (valid, reason) = LessonStore.Validate(lesson);
        Assert.False(valid);
        Assert.NotNull(reason);
    }

    [Fact]
    public void Validate_StepWithBlankInstruction_IsInvalid()
    {
        var lesson = ValidLesson();
        lesson.Steps = [new LessonStep { Instruction = "   ", Check = LessonCheck.UserConfirmation() }];
        var (valid, _) = LessonStore.Validate(lesson);
        Assert.False(valid);
    }

    [Fact]
    public void Validate_BlankTitle_IsInvalid()
    {
        var lesson = ValidLesson();
        lesson.Title = "";
        var (valid, _) = LessonStore.Validate(lesson);
        Assert.False(valid);
    }

    [Fact]
    public void DarkModeBuiltin_IsValid()
    {
        var (valid, reason) = LessonStore.Validate(LessonCatalog.DarkModeBuiltin);
        Assert.True(valid, reason);
    }

    [Fact]
    public void DarkModeBuiltin_HasThreeSteps()
    {
        Assert.Equal(3, LessonCatalog.DarkModeBuiltin.Steps.Count);
    }

    [Fact]
    public void DarkModeBuiltin_LastStepChecksDarkMode()
    {
        Assert.Equal(LessonCheckKind.DarkModeEnabled, LessonCatalog.DarkModeBuiltin.Steps[^1].Check.Kind);
    }
}
