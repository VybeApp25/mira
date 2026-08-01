using Mira.Windows.Core.Learn;
using Xunit;

namespace Mira.Windows.Core.Tests.Learn;

/// <summary>Tests ParseLesson against canned model replies, so tests never make a live Claude call.</summary>
public class LessonAuthorTests
{
    [Fact]
    public void ParseLesson_WellFormedJson_ParsesAllFields()
    {
        const string reply = """{"title": "Add a bookmark", "description": "Save a page for later.", "steps": [{"instruction": "Open the page you want to save.", "remediation": "Navigate there first."}, {"instruction": "Press Ctrl+D.", "remediation": "That's the bookmark shortcut."}]}""";

        var lesson = LessonAuthor.ParseLesson("Edge", reply);

        Assert.Equal("Add a bookmark", lesson.Title);
        Assert.Equal("Save a page for later.", lesson.Description);
        Assert.Equal("Edge", lesson.DomainApp);
        Assert.Equal(2, lesson.Steps.Count);
        Assert.Equal("Open the page you want to save.", lesson.Steps[0].Instruction);
        Assert.Equal("That's the bookmark shortcut.", lesson.Steps[1].Remediation);
        Assert.All(lesson.Steps, s => Assert.Equal(LessonCheckKind.UserConfirmation, s.Check.Kind));
    }

    [Fact]
    public void ParseLesson_JsonWrappedInProseAndFences_StillExtracts()
    {
        const string reply = "Sure, here's a lesson:\n```json\n{\"title\": \"T\", \"description\": \"D\", \"steps\": [{\"instruction\": \"Do it.\", \"remediation\": \"Hint.\"}]}\n```";
        var lesson = LessonAuthor.ParseLesson("App", reply);
        Assert.Equal("T", lesson.Title);
        Assert.Single(lesson.Steps);
    }

    [Fact]
    public void ParseLesson_MissingTitleOrDescription_FallsBackGracefully()
    {
        const string reply = """{"steps": [{"instruction": "Do it."}]}""";
        var lesson = LessonAuthor.ParseLesson("App", reply);
        Assert.Equal("Learn App", lesson.Title);
        Assert.Equal("", lesson.Description);
    }

    [Fact]
    public void ParseLesson_NoJsonObject_Throws()
    {
        Assert.Throws<FormatException>(() => LessonAuthor.ParseLesson("App", "I couldn't come up with a lesson, sorry."));
    }

    [Fact]
    public void ParseLesson_EmptyStepsArray_Throws()
    {
        const string reply = """{"title": "T", "description": "D", "steps": []}""";
        Assert.Throws<FormatException>(() => LessonAuthor.ParseLesson("App", reply));
    }

    [Fact]
    public void ParseLesson_StepMissingInstruction_Throws()
    {
        const string reply = """{"title": "T", "description": "D", "steps": [{"remediation": "Hint only."}]}""";
        Assert.Throws<FormatException>(() => LessonAuthor.ParseLesson("App", reply));
    }
}
