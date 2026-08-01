using Mira.Windows.Core.Providers;
using Mira.Windows.Core.Storage;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Agents;

/// <summary>
/// The Windows equivalent of WebsiteBuilderAgent.swift's <c>ResearchAgent</c>
/// — one Claude call producing a structured markdown report, saved locally.
/// No web search or browsing despite the name — this matches the real Mac
/// behavior exactly (a single thorough-report LLM completion, not an
/// agentic browsing loop), confirmed by reading the actual source rather
/// than assuming from the "research" label.
/// </summary>
public static class DeepResearchAgent
{
    private const string Model = "claude-sonnet-4-6";

    public static async Task<(string ResultText, string? OutputFilePath)> RunAsync(AgentJob job, CancellationToken ct)
    {
        var prompt =
            $"""
            Research the following topic thoroughly and produce a well-structured markdown report with clear headings, key findings, and a brief summary at the top.

            Topic: {job.Prompt}
            """;

        var body = new JObject
        {
            ["model"] = Model,
            ["max_tokens"] = 3000,
            ["messages"] = new JArray { new JObject { ["role"] = "user", ["content"] = prompt } },
        };

        var report = await AnthropicProxyClient.SendAsync(body, ct);

        var dir = LocalAppData.PathFor(Path.Combine("Projects", "Research", job.Id.ToString()));
        Directory.CreateDirectory(dir);
        var filePath = Path.Combine(dir, "report.md");
        await File.WriteAllTextAsync(filePath, report, ct);

        return (report, filePath);
    }
}
