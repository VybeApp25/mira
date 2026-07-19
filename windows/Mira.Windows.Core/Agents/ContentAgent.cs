using Mira.Windows.Core.Providers;
using Mira.Windows.Core.Storage;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Agents;

/// <summary>The Windows equivalent of WebsiteBuilderAgent.swift's <c>ContentAgent</c> — one Claude call producing prose, saved locally.</summary>
public static class ContentAgent
{
    private const string Model = "claude-sonnet-4-6";

    public static async Task<(string ResultText, string? OutputFilePath)> RunAsync(AgentJob job, CancellationToken ct)
    {
        var prompt =
            $"""
            Write the following, in full, ready to use. Match a clear, engaging tone appropriate to the request.

            Request: {job.Prompt}
            """;

        var body = new JObject
        {
            ["model"] = Model,
            ["max_tokens"] = 3000,
            ["messages"] = new JArray { new JObject { ["role"] = "user", ["content"] = prompt } },
        };

        var content = await AnthropicProxyClient.SendAsync(body, ct);

        var dir = LocalAppData.PathFor(Path.Combine("Projects", "Documents", job.Id.ToString()));
        Directory.CreateDirectory(dir);
        var filePath = Path.Combine(dir, "content.md");
        await File.WriteAllTextAsync(filePath, content, ct);

        return (content, filePath);
    }
}
