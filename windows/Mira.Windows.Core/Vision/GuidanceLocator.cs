using System.Text.RegularExpressions;
using Mira.Windows.Core.Providers;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Vision;

/// <summary>
/// The Windows equivalent of ClaudeService.swift's <c>locateGuidanceTarget</c> —
/// a second, JSON-only vision call (separate from the plain-text "describe
/// what you see" reply) that asks Claude for the tight bounding box of the UI
/// element answering the user's question, so the <c>screen_guidance</c> route
/// can both explain AND point at the answer. Same model
/// (<c>claude-sonnet-4-6</c>), same system prompt, same JSON shape and
/// "not visible" sentinel response as the Mac original.
/// </summary>
public static class GuidanceLocator
{
    private const string Model = "claude-sonnet-4-6";

    private const string SystemPrompt =
        "You are a precise UI element locator for a screen guidance overlay. " +
        "Analyze the screenshot and return the bounding box of the exact UI element that answers the user's question. " +
        "Coordinates are physical pixels measured from the top-left corner of the image. " +
        "The bounding box should tightly enclose the element — not the whole panel or window. " +
        "Return ONLY the JSON object, no markdown, no preamble, no trailing text.";

    private static readonly Regex JsonObjectPattern = new(@"\{[\s\S]*\}", RegexOptions.Compiled);

    public static async Task<GuidanceTarget?> LocateAsync(
        string goal, byte[] screenshotJpeg, int screenshotWidth, int screenshotHeight, CancellationToken ct = default)
    {
        var prompt =
            $$"""
            Find the UI element that answers: "{{goal}}"

            Respond ONLY with JSON (no markdown, no explanation):
            {"label":"Short element name (1-4 words)","x":<left edge in physical pixels from left of image>,"y":<top edge in physical pixels from top of image>,"width":<element width in physical pixels>,"height":<element height in physical pixels>,"explanation":"One sentence: what this element is and why it answers the question","confidence":0.90}

            If the element is not visible: {"label":"","x":0,"y":0,"width":0,"height":0,"explanation":"Not visible on screen","confidence":0}
            """;

        var body = new JObject
        {
            ["model"] = Model,
            ["max_tokens"] = 500,
            ["system"] = SystemPrompt,
            ["messages"] = new JArray
            {
                new JObject
                {
                    ["role"] = "user",
                    ["content"] = new JArray
                    {
                        new JObject { ["type"] = "text", ["text"] = prompt },
                        new JObject
                        {
                            ["type"] = "image",
                            ["source"] = new JObject
                            {
                                ["type"] = "base64",
                                ["media_type"] = "image/jpeg",
                                ["data"] = Convert.ToBase64String(screenshotJpeg),
                            },
                        },
                    },
                },
            },
        };

        string raw;
        try { raw = await AnthropicProxyClient.SendAsync(body, ct); }
        catch { return null; }

        var match = JsonObjectPattern.Match(raw);
        if (!match.Success) return null;

        JObject parsed;
        try { parsed = JObject.Parse(match.Value); }
        catch { return null; }

        var confidence = (double?)parsed["confidence"] ?? 0;
        var width = (double?)parsed["width"] ?? 0;
        var height = (double?)parsed["height"] ?? 0;
        if (confidence <= 0 || width <= 0 || height <= 0) return null;

        var rect = new PixelRect((double?)parsed["x"] ?? 0, (double?)parsed["y"] ?? 0, width, height);
        return new GuidanceTarget(
            Guid.NewGuid(), rect, confidence,
            (string?)parsed["label"] ?? "", (string?)parsed["explanation"] ?? "",
            screenshotWidth, screenshotHeight);
    }
}
