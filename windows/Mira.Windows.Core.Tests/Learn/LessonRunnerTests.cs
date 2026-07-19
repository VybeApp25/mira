using Mira.Windows.Core.Learn;
using Xunit;

namespace Mira.Windows.Core.Tests.Learn;

public class LessonRunnerTests
{
    [Fact]
    public void IsCheckSatisfied_AppFrontmost_MatchingProcessCaseInsensitive_IsSatisfied()
    {
        var check = LessonCheck.AppFrontmost("Notepad");
        Assert.True(LessonRunner.IsCheckSatisfied(check, "notepad", darkModeEnabled: false));
    }

    [Fact]
    public void IsCheckSatisfied_AppFrontmost_DifferentProcess_IsNotSatisfied()
    {
        var check = LessonCheck.AppFrontmost("Notepad");
        Assert.False(LessonRunner.IsCheckSatisfied(check, "explorer", darkModeEnabled: false));
    }

    [Fact]
    public void IsCheckSatisfied_AppFrontmost_NullForegroundProcess_IsNotSatisfied()
    {
        var check = LessonCheck.AppFrontmost("Notepad");
        Assert.False(LessonRunner.IsCheckSatisfied(check, null, darkModeEnabled: false));
    }

    [Fact]
    public void IsCheckSatisfied_DarkModeEnabled_TrueWhenDarkModeOn()
    {
        var check = LessonCheck.DarkModeEnabled();
        Assert.True(LessonRunner.IsCheckSatisfied(check, "anything", darkModeEnabled: true));
    }

    [Fact]
    public void IsCheckSatisfied_DarkModeEnabled_FalseWhenDarkModeOff()
    {
        var check = LessonCheck.DarkModeEnabled();
        Assert.False(LessonRunner.IsCheckSatisfied(check, "anything", darkModeEnabled: false));
    }

    [Fact]
    public void IsCheckSatisfied_UserConfirmation_NeverAutoSatisfied()
    {
        var check = LessonCheck.UserConfirmation();
        Assert.False(LessonRunner.IsCheckSatisfied(check, "anything", darkModeEnabled: true));
    }

    [Fact]
    public void IsObservable_UserConfirmation_IsFalse()
    {
        Assert.False(LessonCheck.UserConfirmation().IsObservable);
    }

    [Fact]
    public void IsObservable_AppFrontmostAndDarkMode_AreTrue()
    {
        Assert.True(LessonCheck.AppFrontmost("x").IsObservable);
        Assert.True(LessonCheck.DarkModeEnabled().IsObservable);
    }
}
