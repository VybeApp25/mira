using System.Net.Http.Headers;
using System.Text;
using Mira.Windows.Core.Auth;
using Mira.Windows.Core.Config;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Providers;

/// <summary>
/// The Windows equivalent of the Anthropic call sites in
/// Mira/Services/ClaudeService.swift and Mira/Services/RouterService.swift's
/// <c>haikuClassify</c> — both route through <c>anthropic-proxy</c>
/// (supabase/functions/anthropic-proxy/index.ts), authorized with the signed-in
/// user's JWT rather than an embedded API key (see MiraBackend.swift's
/// <c>authorizeAnthropic</c>). This is a TRANSPARENT proxy of the Anthropic
/// Messages API — request/response bodies here are the real upstream shapes, not
/// the deliberately-unmodeled contract in shared/contracts/edge-functions/anthropic-proxy.schema.json
/// (see that schema's own note: success responses are out of scope to redefine there).
/// </summary>
public static class AnthropicProxyClient
{
    private static readonly HttpClient Http = new();
    private static string Url => $"{MiraConfig.SupabaseUrl}/functions/v1/anthropic-proxy";

    public sealed class AnthropicProxyException(string message, int? statusCode) : Exception(message)
    {
        public int? StatusCode { get; } = statusCode;
    }

    /// <summary>Non-streaming call — returns the concatenated text content. Used by <see cref="Routing.RouterService"/>'s Haiku gate.</summary>
    public static async Task<string> SendAsync(JObject body, CancellationToken ct = default)
    {
        body["stream"] = false;
        using var req = BuildRequest(body);
        using var resp = await Http.SendAsync(req, ct);
        var text = await resp.Content.ReadAsStringAsync(ct);
        if (!resp.IsSuccessStatusCode) throw new AnthropicProxyException(text, (int)resp.StatusCode);

        var parsed = JObject.Parse(text);
        var sb = new StringBuilder();
        if (parsed["content"] is JArray blocks)
            foreach (var block in blocks)
                if ((string?)block["type"] == "text") sb.Append((string?)block["text"]);
        return sb.ToString();
    }

    /// <summary>
    /// Streaming call — invokes <paramref name="onToken"/> once per text delta as
    /// they arrive over the proxy's server-sent-event passthrough (see
    /// anthropic-proxy/index.ts's <c>meterTee</c> transform, which taps but does
    /// not alter the SSE bytes). Returns the full accumulated text once the stream ends.
    /// </summary>
    public static async Task<string> StreamAsync(JObject body, Action<string> onToken, CancellationToken ct = default)
    {
        body["stream"] = true;
        using var req = BuildRequest(body);
        using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        if (!resp.IsSuccessStatusCode)
        {
            var errText = await resp.Content.ReadAsStringAsync(ct);
            throw new AnthropicProxyException(errText, (int)resp.StatusCode);
        }

        await using var stream = await resp.Content.ReadAsStreamAsync(ct);
        using var reader = new StreamReader(stream);
        var full = new StringBuilder();

        while (await reader.ReadLineAsync(ct) is { } line)
        {
            if (!line.StartsWith("data:")) continue;
            var payload = line[5..].Trim();
            if (payload.Length == 0 || payload == "[DONE]") continue;

            JObject evt;
            try { evt = JObject.Parse(payload); }
            catch { continue; } // non-JSON / partial line — ignore, mirrors the server's own tee parser

            if ((string?)evt["type"] != "content_block_delta") continue;
            var delta = evt["delta"];
            if ((string?)delta?["type"] != "text_delta") continue;

            var textDelta = (string?)delta?["text"] ?? "";
            full.Append(textDelta);
            onToken(textDelta);
        }

        return full.ToString();
    }

    private static HttpRequestMessage BuildRequest(JObject body)
    {
        var req = new HttpRequestMessage(HttpMethod.Post, Url)
        {
            Content = new StringContent(body.ToString(Newtonsoft.Json.Formatting.None), Encoding.UTF8, "application/json"),
        };
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", SupabaseService.CachedAccessToken);
        req.Headers.Add("anthropic-version", "2023-06-01");
        return req;
    }
}
