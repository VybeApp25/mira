using Mira.Windows.Core.Storage;

namespace Mira.Windows.Core.Skills;

/// <summary>
/// The disk half of Mira/Services/MiraSkillLoader.swift — loads/saves user
/// skill folders under <c>%LocalAppData%\Mira\PromptSkills\user\&lt;id&gt;\SKILL.md</c>,
/// mirroring the Mac original's <c>userDir</c> layout (no "platform" mirror
/// step in this pass, since Windows has no bundled Resources/Skills set to
/// sync from).
/// </summary>
public static class MiraSkillLoader
{
    private static string UserDir => LocalAppData.PathFor(Path.Combine("PromptSkills", "user"));

    public static List<MiraSkill> LoadUserSkills()
    {
        var result = new List<MiraSkill>();
        if (!Directory.Exists(UserDir)) return result;

        foreach (var dir in Directory.GetDirectories(UserDir))
        {
            var file = Path.Combine(dir, "SKILL.md");
            if (!File.Exists(file)) continue;
            var (skill, _) = MiraSkillParser.Parse(File.ReadAllText(file));
            if (skill is not null) result.Add(skill);
        }
        return result;
    }

    /// <summary>Validates and writes a new user skill folder. <paramref name="reservedIds"/> is every currently-known skill id (builtin + user), mirroring the Mac loader's id-collision rejection.</summary>
    public static (bool Success, string? Error) SaveUserSkill(string markdown, IReadOnlyCollection<string> reservedIds)
    {
        var (skill, error) = MiraSkillParser.Parse(markdown);
        if (skill is null) return (false, error);
        if (reservedIds.Contains(skill.Id)) return (false, $"A skill named \"{skill.Id}\" already exists.");

        var dir = Path.Combine(UserDir, skill.Id);
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "SKILL.md"), markdown);
        return (true, null);
    }

    public static void DeleteUserSkill(string id)
    {
        var dir = Path.Combine(UserDir, id);
        if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
    }
}
