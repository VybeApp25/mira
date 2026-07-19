using System.Diagnostics;
using Mira.Windows.Core.Providers;
using Mira.Windows.Core.Routing;
using Mira.Windows.Core.Skills;
using Mira.Windows.Core.Vision;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Chat;

/// <summary>
/// The Windows equivalent of macOS's <c>RouterService.handle(prompt:context:apiKey:capture:precomputed:onStreamChunk:)</c>
/// — classifies, then dispatches. This is where this port's scope narrows
/// sharply and deliberately: <see cref="Routing.RouterService"/> ported the FULL
/// 32-route classifier faithfully, but only four routes have a real Windows-side
/// handler today (<c>local_response</c>, <c>gpt_query</c>, <c>higher_model</c>,
/// <c>computer_use</c>) — everything else macOS can do (Spotify control,
/// calendar, agent tasks, Codex, ...) has no Windows implementation yet, because
/// none of those underlying services have been built for this client. Rather
/// than silently mis-answering or pretending to do something it can't, an
/// unimplemented route is classified correctly and reported as
/// not-yet-available — "recognize but can't do it" instead of "misclassify."
/// </summary>
public static class RouterHandler
{
    private const string ClaudeChatModel = "claude-sonnet-4-6";

    /// <param name="history">Full conversation so far, with the new user message as the last entry.</param>
    /// <param name="onStreamChunk">Invoked once per token as the Claude reply streams in (only fires for the <c>higher_model</c> route).</param>
    public static async Task<RouteResult> HandleAsync(
        IReadOnlyList<ChatMessage> history, Action<string>? onStreamChunk = null, CancellationToken ct = default)
    {
        var prompt = history[^1].Content;
        var context = new RouterContext(BuildTranscript(history.SkipLast(1)), history.Count - 1);
        var decision = await RouterService.Shared.ClassifyIntentAsync(prompt, context, ct);

        return decision.Route switch
        {
            MiraRoute.ClarificationRequired => new RouteResult(RouteResultKind.Clarify,
                decision.ClarificationQuestion ?? "Can you be more specific about what you'd like me to do?", decision.Route),

            MiraRoute.ConfirmationRequired => new RouteResult(RouteResultKind.Confirm,
                decision.ConfirmationSummary ?? prompt, decision.Route),

            MiraRoute.PermissionRequired => new RouteResult(RouteResultKind.NotAvailable,
                "A required permission is missing.", decision.Route),

            MiraRoute.LocalResponse => await LocalOrEscalatedReplyAsync(prompt, history, onStreamChunk, decision.Route, ct),

            MiraRoute.GptQuery => new RouteResult(RouteResultKind.Reply, await GptReplyAsync(prompt, ct), decision.Route),

            MiraRoute.HigherModel => new RouteResult(RouteResultKind.Reply,
                await AnthropicProxyClient.StreamAsync(BuildClaudeBody(history), onStreamChunk ?? (_ => { }), ct),
                decision.Route),

            MiraRoute.ComputerUse => await ComputerUseReplyAsync(prompt, ct),

            MiraRoute.ScreenGuidance => await ScreenGuidanceReplyAsync(prompt, onStreamChunk, ct),

            MiraRoute.WebSearch => await WebSearchReplyAsync(prompt, ct),

            _ => new RouteResult(RouteResultKind.NotAvailable, NotAvailableMessage(decision), decision.Route),
        };
    }

    /// <summary>
    /// Mirrors RouterService.swift's <c>.computerUse</c> case exactly: a chat
    /// request can only drive the screen if the user has explicitly turned on
    /// autonomous mode (<see cref="AutonomySettings.ComputerUseEnabled"/>,
    /// off by default) — otherwise it falls back to a plain reply explaining
    /// that, rather than silently doing nothing or silently acting without consent.
    /// </summary>
    private static async Task<RouteResult> ComputerUseReplyAsync(string prompt, CancellationToken ct)
    {
        if (!AutonomySettings.ComputerUseEnabled)
        {
            return new RouteResult(RouteResultKind.NotAvailable,
                "That would need me to control your screen, and autonomous mode is off. Turn it on in Settings if you want me to act on this.",
                MiraRoute.ComputerUse);
        }

        var result = await ComputerUseOrchestrator.Shared.RunAsync(prompt, ct);
        return new RouteResult(RouteResultKind.Reply, string.IsNullOrEmpty(result) ? "Done." : result, MiraRoute.ComputerUse);
    }

    /// <summary>
    /// Mirrors RouterService.swift's <c>.screenGuidance</c> case: describes what's
    /// on screen (streamed, same as <c>higher_model</c>) AND, in parallel,
    /// asks <see cref="GuidanceLocator"/> to find the specific element that
    /// answers the question. If one's found with enough confidence, it's
    /// published to <see cref="GuidanceOverlayHub"/> so the WPF app can both
    /// point at it (flying triangle) and highlight it (box + label +
    /// explanation) — ported from <c>ClaudeService.locateGuidanceTarget</c> +
    /// <c>OverlayWindowController.showGuidance</c>/<c>PointToService</c>.
    /// </summary>
    private static async Task<RouteResult> ScreenGuidanceReplyAsync(string prompt, Action<string>? onStreamChunk, CancellationToken ct)
    {
        var jpeg = ScreenCapture.CaptureJpeg();
        if (jpeg is null)
        {
            return new RouteResult(RouteResultKind.NotAvailable,
                "I can't capture your screen right now.", MiraRoute.ScreenGuidance);
        }

        var describeBody = new JObject
        {
            ["model"] = ClaudeChatModel,
            ["max_tokens"] = 600,
            ["system"] = "You are Mira, a screen-aware Windows assistant. You CAN see the user's screen — a screenshot is attached to this message. Describe what you see accurately. Be concise and direct.",
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
                            ["source"] = new JObject { ["type"] = "base64", ["media_type"] = "image/jpeg", ["data"] = Convert.ToBase64String(jpeg) },
                        },
                    },
                },
            },
        };

        var describeTask = AnthropicProxyClient.StreamAsync(describeBody, onStreamChunk ?? (_ => { }), ct);
        var locateTask = GuidanceLocator.LocateAsync(prompt, jpeg, ScreenCapture.DisplayWidth, ScreenCapture.DisplayHeight, ct);

        string text;
        try { text = await describeTask; }
        catch (Exception ex) { text = $"I couldn't process the screenshot: {ex.Message}"; }

        var target = await locateTask;
        if (target is not null) GuidanceOverlayHub.Publish(target);

        return new RouteResult(RouteResultKind.Reply, text, MiraRoute.ScreenGuidance);
    }

    /// <summary>
    /// The Windows equivalent of RouterService.swift's <c>webSearchResult</c>/
    /// <c>webSearchAnswer</c> — this is what was missing when a live query
    /// ("what time is the world cup game tonight, who's playing") fell
    /// through to the generic "not built yet" message despite the classifier
    /// correctly recognizing it as web_search. Mac's fix here needs no new
    /// infrastructure: it's a single Claude call using Anthropic's own
    /// server-side <c>web_search_20250305</c> tool (the API fetches and reads
    /// live pages itself; no client-side scraping/browser automation), plus
    /// opening the user's browser to the same query so they can see the full
    /// results — ported as-is since both halves are already fully portable
    /// through the existing <see cref="AnthropicProxyClient"/>.
    /// </summary>
    private static async Task<RouteResult> WebSearchReplyAsync(string prompt, CancellationToken ct)
    {
        var query = ExtractSearchQuery(prompt);

        try
        {
            Process.Start(new ProcessStartInfo($"https://www.google.com/search?q={Uri.EscapeDataString(query)}") { UseShellExecute = true });
        }
        catch
        {
            // Best-effort -- a failed browser launch shouldn't block the spoken answer below.
        }

        var body = new JObject
        {
            ["model"] = "claude-haiku-4-5-20251001",
            ["max_tokens"] = 500,
            ["system"] = "You are Mira. Use web search to answer with current, accurate information. Reply in 1-3 plain spoken sentences. No markdown, no bullet lists, no citation list.",
            ["tools"] = new JArray { new JObject { ["type"] = "web_search_20250305", ["name"] = "web_search", ["max_uses"] = 3 } },
            ["messages"] = new JArray { new JObject { ["role"] = "user", ["content"] = prompt } },
        };

        try
        {
            var answer = await AnthropicProxyClient.SendAsync(body, ct);
            var text = string.IsNullOrWhiteSpace(answer)
                ? "I opened the results in your browser — take a look."
                : $"{answer.Trim()}\n\n_Opened the full results in your browser._";
            return new RouteResult(RouteResultKind.Reply, text, MiraRoute.WebSearch);
        }
        catch
        {
            return new RouteResult(RouteResultKind.Reply, "I opened the results in your browser — take a look.", MiraRoute.WebSearch);
        }
    }

    /// <summary>Pure — strips leading filler so the browser query is clean, extracted for direct unit-testing. Mirrors <c>RouterService.searchQuery(from:)</c>.</summary>
    public static string ExtractSearchQuery(string prompt)
    {
        var q = prompt.Trim();
        string[] prefixes = ["search the web for ", "search online for ", "search for ", "look up ", "look it up ", "google ", "search "];
        foreach (var prefix in prefixes)
        {
            if (q.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                q = q[prefix.Length..];
                break;
            }
        }
        return q.Length == 0 ? prompt : q;
    }

    /// <summary>
    /// local_response covers genuine small talk (canned, instant) AND anything
    /// the classifier judged "answerable without tools or live data" — the
    /// latter is often a real question ("what day is it", "what's 12% of 340")
    /// that <see cref="RouterService.LocalReply"/> has no canned line for. A
    /// bare fallback string there ("Got it.") is indistinguishable from the
    /// assistant not understanding at all, which is exactly what got reported
    /// as "not actually smart... only hallucinations." So: use the canned
    /// reply when one truly fits, otherwise fall through to the same real
    /// Claude call <see cref="MiraRoute.HigherModel"/> uses — a correct answer
    /// beats a fast non-answer.
    /// </summary>
    private static async Task<RouteResult> LocalOrEscalatedReplyAsync(
        string prompt, IReadOnlyList<ChatMessage> history, Action<string>? onStreamChunk, MiraRoute route, CancellationToken ct)
    {
        var canned = RouterService.LocalReply(prompt);
        if (canned is not null) return new RouteResult(RouteResultKind.Reply, canned, route);

        var reply = await AnthropicProxyClient.StreamAsync(BuildClaudeBody(history), onStreamChunk ?? (_ => { }), ct);
        return new RouteResult(RouteResultKind.Reply, reply, route);
    }

    private static async Task<string> GptReplyAsync(string prompt, CancellationToken ct)
    {
        var reply = await OpenAIProxyClient.ChatOrEmptyAsync(prompt, 800, ct);
        return string.IsNullOrEmpty(reply) ? "GPT-4o returned no response." : reply;
    }

    /// <summary>
    /// Splices every currently-active skill's context text into the system
    /// prompt (see <see cref="SkillStore.BuildContext"/>) — the one and only
    /// effect a "skill" has on Windows, mirroring the Mac original's own
    /// design exactly: a skill is text, not code, and toggling it on just
    /// biases what the model writes back, nothing else.
    /// </summary>
    private static JObject BuildClaudeBody(IReadOnlyList<ChatMessage> history)
    {
        var body = new JObject
        {
            ["model"] = ClaudeChatModel,
            ["max_tokens"] = 2048,
            ["messages"] = new JArray(history.Select(m => new JObject
            {
                ["role"] = m.Role == ChatRole.User ? "user" : "assistant",
                ["content"] = m.Content,
            })),
        };

        var skillContext = SkillStore.Shared.BuildContext();
        if (!string.IsNullOrEmpty(skillContext)) body["system"] = skillContext;
        return body;
    }

    /// <summary>Condensed transcript for the classifier's context, mirroring the shape <c>RouterContext.recentTranscript</c> carries on macOS — last few turns only.</summary>
    private static string? BuildTranscript(IEnumerable<ChatMessage> priorMessages)
    {
        var list = priorMessages.TakeLast(6).ToList();
        if (list.Count == 0) return null;
        return string.Join("\n", list.Select(m => $"{(m.Role == ChatRole.User ? "User" : "Mira")}: {m.Content}"));
    }

    private static string NotAvailableMessage(RouteDecision decision) =>
        $"I recognized that as a \"{decision.Explanation}\" request, but that capability isn't built into the Windows client yet — it's on the roadmap. For now I can chat, answer questions, and (if you explicitly ask GPT) route to GPT-4o.";
}
