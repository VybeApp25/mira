using Mira.Windows.Core.Providers;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Skills;

/// <summary>
/// The Windows equivalent of ClaudeService.generateSkillMarkdown(description:)
/// — generates a SKILL.md text file from a plain-English description. Same
/// safety shape as any hand-written skill: the output is plain directive
/// text spliced into a future system prompt, never executed as code, so
/// there's nothing here for the model to generate that could itself "run."
/// </summary>
public static class SkillAuthor
{
    private const string Model = "claude-sonnet-4-6";

    private const string SystemPrompt =
        "You write SKILL.md files for Mira, a Windows AI assistant. A SKILL.md is plain text injected verbatim into Mira's system prompt when the skill is toggled on -- it is NOT executable code, just directive instructions telling Mira how to respond. " +
        "Output ONLY the contents of a SKILL.md file: a frontmatter block (a line with just ---, then name:/title:/tagline:/category:/icon: fields each on their own line, then a line with just ---), followed by 2-8 concrete, directive sentences telling Mira exactly how to behave when this skill is active. " +
        "The name field must be a short kebab-case identifier. Do not wrap the output in markdown code fences and do not add any commentary before or after.";

    public static async Task<string> GenerateAsync(string description, CancellationToken ct = default)
    {
        var body = new JObject
        {
            ["model"] = Model,
            ["max_tokens"] = 500,
            ["system"] = SystemPrompt,
            ["messages"] = new JArray { new JObject { ["role"] = "user", ["content"] = $"Create a skill for: {description}" } },
        };

        var raw = await AnthropicProxyClient.SendAsync(body, ct);
        return raw.Trim().Replace("```markdown", "").Replace("```", "").Trim();
    }
}
