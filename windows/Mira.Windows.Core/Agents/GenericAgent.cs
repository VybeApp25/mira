using Mira.Windows.Core.Providers;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Agents;

/// <summary>
/// The Windows equivalent of WebsiteBuilderAgent.swift's <c>GenericAgent</c>
/// — the fallback for any job type without a dedicated runner. Matches the
/// Mac original exactly: one plain Claude completion, no file output (the
/// Mac source has no file write here either, unlike DeepResearch/Content).
/// </summary>
public static class GenericAgent
{
    private const string Model = "claude-sonnet-4-6";

    public static async Task<(string ResultText, string? OutputFilePath)> RunAsync(AgentJob job, CancellationToken ct)
    {
        var body = new JObject
        {
            ["model"] = Model,
            ["max_tokens"] = 2000,
            ["messages"] = new JArray { new JObject { ["role"] = "user", ["content"] = job.Prompt } },
        };

        var result = await AnthropicProxyClient.SendAsync(body, ct);
        return (result, null);
    }
}
