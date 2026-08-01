using System.Net;
using System.Net.Http.Headers;
using System.Text;
using Mira.Windows.Core.Auth;
using Mira.Windows.Core.Config;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Providers;

/// <summary>
/// The Windows equivalent of Mira/Services/OpenAIService.swift's
/// <c>chatOrEmpty</c>, routed through <c>openai-proxy</c> the same way
/// <see cref="AnthropicProxyClient"/> routes through <c>anthropic-proxy</c>. Used
/// by the <c>gpt_query</c> route (an explicit "ask GPT" request) — see
/// shared/contracts/edge-functions/openai-proxy.schema.json for the request
/// fields this proxy actually validates (model allowlist, max_tokens cap).
///
/// Reacts to a 401 with one refresh-and-retry, same as
/// <see cref="AnthropicProxyClient"/> and for the same reason — see that
/// class's doc comment for the bug this fixes.
/// </summary>
public static class OpenAIProxyClient
{
    private static readonly HttpClient Http = new();
    private static string Url => $"{MiraConfig.SupabaseUrl}/functions/v1/openai-proxy";

    /// <summary>Non-streaming chat completion. Returns empty string on any failure — mirrors <c>chatOrEmpty</c>'s name and behavior exactly.</summary>
    public static async Task<string> ChatOrEmptyAsync(string prompt, int maxTokens = 800, CancellationToken ct = default)
    {
        try
        {
            var body = new JObject
            {
                ["model"] = "gpt-4o",
                ["max_tokens"] = maxTokens,
                ["messages"] = new JArray { new JObject { ["role"] = "user", ["content"] = prompt } },
            };

            var resp = await SendOnceAsync(body, ct);
            if (resp.StatusCode == HttpStatusCode.Unauthorized)
            {
                resp.Dispose();
                if (!await SupabaseService.Shared.RefreshAfter401Async(ct)) return "";
                resp = await SendOnceAsync(body, ct);
            }

            using var _ = resp;
            var text = await resp.Content.ReadAsStringAsync(ct);
            if (!resp.IsSuccessStatusCode) return "";

            var parsed = JObject.Parse(text);
            return (string?)parsed["choices"]?[0]?["message"]?["content"] ?? "";
        }
        catch
        {
            return "";
        }
    }

    private static async Task<HttpResponseMessage> SendOnceAsync(JObject body, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, Url)
        {
            Content = new StringContent(body.ToString(Newtonsoft.Json.Formatting.None), Encoding.UTF8, "application/json"),
        };
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", SupabaseService.CachedAccessToken);
        return await Http.SendAsync(req, ct);
    }
}
