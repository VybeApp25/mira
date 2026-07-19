using Mira.Windows.Core.Providers;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Learn;

/// <summary>
/// The Windows equivalent of the goal-authored half (LA-1) of
/// Mira/Services/LessonScaffolder.swift's <c>author(goal:app:)</c> --
/// one Claude call producing strict JSON, same shape as
/// <see cref="Skills.SkillAuthor"/> and <see cref="Agents.ContentAgent"/>.
/// Tutorial-authored (LA-2, YouTube transcript -&gt; lesson) is not ported
/// this pass -- it needs a Python transcript-extraction dependency the Mac
/// original also reaches for externally, a separate, deferrable slice.
/// </summary>
public static class LessonAuthor
{
    private const string Model = "claude-sonnet-4-6";

    public static async Task<Lesson> AuthorAsync(string appDisplayName, string goal, CancellationToken ct = default)
    {
        const string jsonShape = """{"title": "...", "description": "...", "steps": [{"instruction": "...", "remediation": "..."}]}""";
        var prompt =
            $"""
            Write a short step-by-step lesson teaching a user how to do the following in {appDisplayName} on Windows: "{goal}"

            Reply with ONLY a JSON object, no prose, no markdown fences, in exactly this shape:
            {jsonShape}

            3 to 6 steps. Each "instruction" must be one concrete, actionable sentence the user can follow while looking at their own screen right now. "remediation" is a short hint shown if the user gets stuck (under 20 words).
            """;

        var body = new JObject
        {
            ["model"] = Model,
            ["max_tokens"] = 1200,
            ["messages"] = new JArray { new JObject { ["role"] = "user", ["content"] = prompt } },
        };

        var raw = await AnthropicProxyClient.SendAsync(body, ct);
        return ParseLesson(appDisplayName, raw);
    }

    /// <summary>
    /// Pure — parses and validates the model's JSON reply into a
    /// <see cref="Lesson"/>, extracted so it's testable against canned text
    /// without a live Claude call. Every step is given a
    /// <see cref="LessonCheckKind.UserConfirmation"/> check rather than
    /// guessing at a deterministic one — this port has no vision-grounding
    /// to verify an arbitrary authored step, and faking a check the model
    /// didn't actually specify would violate the whole feature's honesty
    /// principle (see <c>TeachingEngine.swift</c>'s own header comment).
    /// </summary>
    public static Lesson ParseLesson(string appDisplayName, string rawReply)
    {
        var start = rawReply.IndexOf('{');
        var end = rawReply.LastIndexOf('}');
        if (start < 0 || end <= start) throw new FormatException("No JSON object found in the model's reply.");

        var json = JObject.Parse(rawReply[start..(end + 1)]);
        if (json["steps"] is not JArray stepsArray || stepsArray.Count == 0)
            throw new FormatException("The model's reply had no steps.");

        var steps = stepsArray.Select(s =>
        {
            var instruction = (string?)s["instruction"];
            if (string.IsNullOrWhiteSpace(instruction)) throw new FormatException("A step is missing its instruction.");
            return new LessonStep
            {
                Instruction = instruction,
                Check = LessonCheck.UserConfirmation(),
                Remediation = (string?)s["remediation"],
            };
        }).ToList();

        return new Lesson
        {
            Id = Guid.NewGuid().ToString(),
            Title = (string?)json["title"] ?? $"Learn {appDisplayName}",
            Description = (string?)json["description"] ?? "",
            DomainApp = appDisplayName,
            IsBuiltin = false,
            Steps = steps,
        };
    }
}
