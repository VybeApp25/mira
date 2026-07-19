using Mira.Windows.Core.Learn;
using Xunit;

namespace Mira.Windows.Core.Tests.Learn;

public class LessonScaffolderTests
{
    [Fact]
    public void BuildTemplate_WithProcessName_UsesAppFrontmostForFirstStep()
    {
        var lesson = LessonScaffolder.BuildTemplate("Notepad", "notepad");
        Assert.Equal(LessonCheckKind.AppFrontmost, lesson.Steps[0].Check.Kind);
        Assert.Equal("notepad", lesson.Steps[0].Check.ProcessName);
    }

    [Fact]
    public void BuildTemplate_WithoutProcessName_FallsBackToUserConfirmation()
    {
        var lesson = LessonScaffolder.BuildTemplate("SomeApp", null);
        Assert.Equal(LessonCheckKind.UserConfirmation, lesson.Steps[0].Check.Kind);
    }

    [Fact]
    public void BuildTemplate_HasThreeSteps()
    {
        var lesson = LessonScaffolder.BuildTemplate("Notepad", "notepad");
        Assert.Equal(3, lesson.Steps.Count);
    }

    [Fact]
    public void BuildTemplate_IsValid()
    {
        var lesson = LessonScaffolder.BuildTemplate("Notepad", "notepad");
        var (valid, reason) = LessonStore.Validate(lesson);
        Assert.True(valid, reason);
    }
}
