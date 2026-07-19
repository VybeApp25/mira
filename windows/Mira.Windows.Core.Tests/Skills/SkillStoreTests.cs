using Mira.Windows.Core.Skills;
using Xunit;

namespace Mira.Windows.Core.Tests.Skills;

/// <summary>Tests the pure BuildContextFrom join directly rather than the live singleton, so tests never mutate this machine's real active-skill state on disk.</summary>
public class SkillStoreTests
{
    private static MiraSkill Skill(string id, string context) =>
        new() { Id = id, Name = id, Tagline = "", Icon = "🧩", Category = "test", Context = context, Origin = MiraSkillOrigin.Builtin };

    [Fact]
    public void BuildContextFrom_NoActiveSkills_ReturnsEmptyString()
    {
        var skills = new[] { Skill("a", "context a") };
        var result = SkillStore.BuildContextFrom(skills, new HashSet<string>());
        Assert.Equal("", result);
    }

    [Fact]
    public void BuildContextFrom_OneActiveSkill_ReturnsItsContext()
    {
        var skills = new[] { Skill("a", "context a"), Skill("b", "context b") };
        var result = SkillStore.BuildContextFrom(skills, new HashSet<string> { "a" });
        Assert.Equal("context a", result);
    }

    [Fact]
    public void BuildContextFrom_MultipleActiveSkills_JoinsWithBlankLine()
    {
        var skills = new[] { Skill("a", "context a"), Skill("b", "context b") };
        var result = SkillStore.BuildContextFrom(skills, new HashSet<string> { "a", "b" });
        Assert.Equal("context a\n\ncontext b", result);
    }

    [Fact]
    public void BuiltinCatalog_HasNoDuplicateIds()
    {
        var ids = MiraSkillCatalog.Builtins.Select(s => s.Id).ToList();
        Assert.Equal(ids.Count, ids.Distinct().Count());
    }
}
