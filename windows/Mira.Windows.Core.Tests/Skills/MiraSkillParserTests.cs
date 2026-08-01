using Mira.Windows.Core.Skills;
using Xunit;

namespace Mira.Windows.Core.Tests.Skills;

public class MiraSkillParserTests
{
    private const string ValidMarkdown = """
        ---
        name: my-test-skill
        title: My Test Skill
        tagline: A skill for testing
        category: testing
        icon: 🧪
        ---
        Always respond in haiku form.
        """;

    [Fact]
    public void Parse_ValidMarkdown_ProducesExpectedSkill()
    {
        var (skill, error) = MiraSkillParser.Parse(ValidMarkdown);

        Assert.Null(error);
        Assert.NotNull(skill);
        Assert.Equal("my-test-skill", skill!.Id);
        Assert.Equal("My Test Skill", skill.Name);
        Assert.Equal("A skill for testing", skill.Tagline);
        Assert.Equal("testing", skill.Category);
        Assert.Equal("🧪", skill.Icon);
        Assert.Equal("Always respond in haiku form.", skill.Context);
        Assert.Equal(MiraSkillOrigin.User, skill.Origin);
    }

    [Fact]
    public void Parse_MissingLeadingDelimiter_Fails()
    {
        var (skill, error) = MiraSkillParser.Parse("name: foo\n---\nbody");
        Assert.Null(skill);
        Assert.Contains("must start with", error);
    }

    [Fact]
    public void Parse_UnclosedFrontmatter_Fails()
    {
        var (skill, error) = MiraSkillParser.Parse("---\nname: foo\nno closing delimiter here");
        Assert.Null(skill);
        Assert.Contains("never closed", error);
    }

    [Fact]
    public void Parse_MissingNameField_Fails()
    {
        var (skill, error) = MiraSkillParser.Parse("---\ntitle: No Name Here\n---\nbody text");
        Assert.Null(skill);
        Assert.Contains("must declare a 'name:'", error);
    }

    [Fact]
    public void Parse_MissingOptionalFields_FallsBackToDefaults()
    {
        var (skill, error) = MiraSkillParser.Parse("---\nname: bare-skill\n---\nJust the body.");
        Assert.Null(error);
        Assert.NotNull(skill);
        Assert.Equal("bare-skill", skill!.Name); // falls back to name when title is absent
        Assert.Equal("", skill.Tagline);
        Assert.Equal("custom", skill.Category);
        Assert.Equal("🧩", skill.Icon);
    }

    [Fact]
    public void Parse_EmptyBody_GetsPlaceholderContext()
    {
        var (skill, _) = MiraSkillParser.Parse("---\nname: empty-body\n---\n");
        Assert.NotNull(skill);
        Assert.Contains("empty-body", skill!.Context);
        Assert.Contains("no additional instructions", skill.Context);
    }
}
