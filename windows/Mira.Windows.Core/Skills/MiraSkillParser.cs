namespace Mira.Windows.Core.Skills;

/// <summary>
/// Pure parsing logic for a <c>SKILL.md</c> file — extracted separately from
/// <see cref="MiraSkillLoader"/> (which does the disk I/O) so it's directly
/// unit-testable. Mirrors <c>MiraSkillLoader.parse()</c>'s hand-rolled
/// frontmatter format exactly: a leading <c>---</c> block of <c>key: value</c>
/// lines, a closing <c>---</c>, then a markdown body that becomes the
/// skill's <see cref="MiraSkill.Context"/> verbatim — no YAML library on
/// either platform.
/// </summary>
public static class MiraSkillParser
{
    public static (MiraSkill? Skill, string? Error) Parse(string markdown)
    {
        var lines = markdown.Replace("\r\n", "\n").Split('\n');
        if (lines.Length == 0 || lines[0].Trim() != "---")
            return (null, "SKILL.md must start with a '---' frontmatter block.");

        var fields = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var i = 1;
        for (; i < lines.Length; i++)
        {
            if (lines[i].Trim() == "---") break;
            var line = lines[i];
            var idx = line.IndexOf(':');
            if (idx < 0) continue;
            fields[line[..idx].Trim()] = line[(idx + 1)..].Trim();
        }
        if (i >= lines.Length) return (null, "Frontmatter block was never closed with a trailing '---'.");

        if (!fields.TryGetValue("name", out var name) || string.IsNullOrWhiteSpace(name))
            return (null, "SKILL.md must declare a 'name:' field in its frontmatter.");

        var body = string.Join("\n", lines.Skip(i + 1)).Trim();
        var skill = new MiraSkill
        {
            Id = name,
            Name = fields.GetValueOrDefault("title", name),
            Tagline = fields.GetValueOrDefault("tagline", ""),
            Icon = fields.GetValueOrDefault("icon", "🧩"),
            Category = fields.GetValueOrDefault("category", "custom"),
            // A metadata-only skill still injects something meaningful, mirroring the Mac loader's own comment.
            Context = string.IsNullOrWhiteSpace(body) ? $"(Skill '{name}' has no additional instructions.)" : body,
            Origin = MiraSkillOrigin.User,
        };
        return (skill, null);
    }
}
