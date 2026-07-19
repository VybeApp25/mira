using System.Diagnostics;
using System.Text.RegularExpressions;
using Mira.Windows.Core.Browser;
using Mira.Windows.Core.LiveLookup;
using Mira.Windows.Core.Memory;
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

            MiraRoute.WeatherLookup => await WeatherLookupReplyAsync(prompt, ct),

            MiraRoute.StockLookup => await StockLookupReplyAsync(prompt, ct),

            MiraRoute.PlaceSearch => await PlaceSearchReplyAsync(prompt, ct),

            MiraRoute.MapsQuery => await MapsQueryReplyAsync(prompt, ct),

            MiraRoute.ImageSearch => ImageSearchReply(prompt),

            MiraRoute.VideoPlayback => VideoPlaybackReply(prompt),

            MiraRoute.OpenUrl => OpenUrlReply(prompt),

            MiraRoute.MusicQuery => await MusicQueryReplyAsync(),

            MiraRoute.SpotifyControl => await SpotifyControlReplyAsync(prompt),

            MiraRoute.MemoryQuery => MemoryQueryReply(prompt),

            MiraRoute.MemoryWrite => await MemoryWriteReplyAsync(prompt, ct),

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

        // The Windows equivalent of Mac's "Confirm risky actions" Autonomous
        // setting ("Pause before anything irreversible: send, delete, buy,
        // submit…"). This port's ComputerUseOrchestrator runs as a single
        // synchronous loop with no mid-task pause point built in, so this is
        // a pre-flight gate rather than a per-step one -- reuses the existing
        // RouteResultKind.Confirm flow the classifier already produces for
        // other routes, rather than inventing new UI just for this.
        if (AutonomySettings.ConfirmRiskyActions && IsRiskyPrompt(prompt))
        {
            return new RouteResult(RouteResultKind.Confirm,
                $"This looks like it might do something hard to undo: \"{prompt}\". Want me to go ahead? (You can turn this check off in Settings.)",
                MiraRoute.ComputerUse);
        }

        var result = await ComputerUseOrchestrator.Shared.RunAsync(prompt, ct);
        return new RouteResult(RouteResultKind.Reply, string.IsNullOrEmpty(result) ? "Done." : result, MiraRoute.ComputerUse);
    }

    private static readonly string[] RiskyKeywords =
    [
        "send", "delete", "buy", "purchase", "pay", "submit", "transfer",
        "remove", "uninstall", "cancel", "unsubscribe", "checkout", "order",
    ];

    /// <summary>Pure — a deliberately simple keyword heuristic, matching the spirit (not a literal port) of Mac's own "send, delete, buy, submit…" example list.</summary>
    public static bool IsRiskyPrompt(string prompt)
    {
        var lower = prompt.ToLowerInvariant();
        return RiskyKeywords.Any(k => lower.Contains(k));
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
            BrowserLauncher.Open($"https://www.google.com/search?q={Uri.EscapeDataString(query)}");
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

    /// <summary>The Windows equivalent of RouterService.swift's <c>weatherResult</c> — the spoken half only; see <see cref="LiveLookup.WeatherLookup"/>'s doc comment for why the Weather-app-opening half isn't ported.</summary>
    private static async Task<RouteResult> WeatherLookupReplyAsync(string prompt, CancellationToken ct)
    {
        var city = WeatherLookup.ExtractCity(prompt);
        var summary = await WeatherLookup.LookupAsync(city, ct);
        var text = summary ?? (city is null ? "I couldn't get the weather right now." : $"I couldn't get the weather for {city} right now.");
        return new RouteResult(RouteResultKind.Reply, text, MiraRoute.WeatherLookup);
    }

    /// <summary>The Windows equivalent of RouterService.swift's <c>stockLookup</c> case — answers with text directly (Mac's widget-card path has no Windows chat-UI equivalent yet).</summary>
    private static async Task<RouteResult> StockLookupReplyAsync(string prompt, CancellationToken ct)
    {
        var quote = await StockLookup.LookupAsync(prompt, ct);
        var text = quote ?? "I couldn't find a quote for that — try naming the ticker symbol, like \"AAPL\".";
        return new RouteResult(RouteResultKind.Reply, text, MiraRoute.StockLookup);
    }

    /// <summary>The Windows equivalent of RouterService.swift's <c>placeSearch</c> case — a single Nominatim lookup answered as text (Mac's widget-card/map path has no Windows chat-UI equivalent yet).</summary>
    private static async Task<RouteResult> PlaceSearchReplyAsync(string prompt, CancellationToken ct)
    {
        var query = PlaceLookup.ExtractPlaceQuery(prompt);
        var place = await PlaceLookup.LookupAsync(query, ct);
        var text = place is null
            ? $"I couldn't find \"{query}\" — try a more specific name or address."
            : $"{place.Name} — {place.Address}";
        return new RouteResult(RouteResultKind.Reply, text, MiraRoute.PlaceSearch);
    }

    /// <summary>
    /// The Windows equivalent of RouterService.swift's <c>mapsQuery</c> case
    /// — scoped down to "where is X" location lookups (reusing the same
    /// Nominatim client as <see cref="PlaceSearchReplyAsync"/>, matching how
    /// Mac's own Python maps skill uses the same OSRM/Nominatim combination),
    /// plus opening the location on Google Maps. Turn-by-turn routing
    /// ("directions from X to Y") is not ported this pass — see
    /// docs/windows/IMPLEMENTATION_PLAN.md.
    /// </summary>
    private static async Task<RouteResult> MapsQueryReplyAsync(string prompt, CancellationToken ct)
    {
        var query = PlaceLookup.ExtractPlaceQuery(prompt);
        var place = await PlaceLookup.LookupAsync(query, ct);
        if (place is null)
        {
            return new RouteResult(RouteResultKind.Reply,
                $"I couldn't find \"{query}\" on the map — try a more specific name or address.", MiraRoute.MapsQuery);
        }

        try
        {
            BrowserLauncher.Open($"https://www.google.com/maps/search/?api=1&query={place.Lat},{place.Lon}");
        }
        catch
        {
            // Best-effort -- a failed browser launch shouldn't block the spoken answer below.
        }

        return new RouteResult(RouteResultKind.Reply, $"{place.Name} — {place.Address}. Opened it on the map for you.", MiraRoute.MapsQuery);
    }

    /// <summary>
    /// The Windows equivalent of RouterService.swift's <c>imageSearch</c>
    /// case — Mac's real data source (an unofficial DuckDuckGo scrape feeding
    /// a thumbnail-grid widget in <c>IslandChatView</c>) has no equivalent
    /// surface in Windows' plain-text chat yet, so rather than fetching image
    /// URLs just to print them as a text list, this opens the same DuckDuckGo
    /// image-results page directly — arguably a better outcome for an image
    /// query than a list of raw links would be.
    /// </summary>
    private static RouteResult ImageSearchReply(string prompt)
    {
        var query = ImageQuery(prompt);
        try
        {
            BrowserLauncher.Open($"https://duckduckgo.com/?q={Uri.EscapeDataString(query)}&iax=images&ia=images");
            return new RouteResult(RouteResultKind.Reply, $"Opened image results for \"{query}\" in your browser.", MiraRoute.ImageSearch);
        }
        catch
        {
            return new RouteResult(RouteResultKind.NotAvailable, "I couldn't open a browser to search images right now.", MiraRoute.ImageSearch);
        }
    }

    /// <summary>Pure — mirrors <c>ChatWidgetService.imageQuery(from:)</c>'s filler-stripping.</summary>
    public static string ImageQuery(string prompt)
    {
        var lower = prompt.ToLowerInvariant();
        string[] strips = ["show me images of ", "images of ", "pictures of ", "show me pictures of ", "search images for ", "find images of ", "search for images of "];
        foreach (var strip in strips)
        {
            if (lower.StartsWith(strip, StringComparison.Ordinal))
                return prompt[strip.Length..].Trim();
        }
        return prompt;
    }

    /// <summary>The Windows equivalent of RouterService.swift's <c>videoPlayback</c> case — deterministic, no Claude call: clean the query, open YouTube's search results.</summary>
    private static RouteResult VideoPlaybackReply(string prompt)
    {
        var query = VideoQuery(prompt);
        try
        {
            BrowserLauncher.Open($"https://www.youtube.com/results?search_query={Uri.EscapeDataString(query)}");
            return new RouteResult(RouteResultKind.Reply, $"Pulling up \"{query}\" on YouTube in your browser — top result's right there.", MiraRoute.VideoPlayback);
        }
        catch
        {
            return new RouteResult(RouteResultKind.Reply, "I couldn't work out what to search for — try naming the video.", MiraRoute.VideoPlayback);
        }
    }

    private static readonly string[] VideoQueryStrip =
    [
        "bring up", "pull up", "pull that up", "pull it up", "put on", "throw on",
        "show me", "play me", "play the", "play a", "play", "find me", "let me see",
        "i want to watch", "i wanna watch", "i want to see", "can you", "could you",
        "would you", "please", "for me", "real quick",
        "a youtube video", "the youtube video", "youtube video", "on youtube",
        "the youtube", "youtube", "the video of", "a video of", "video of",
        "the video", "a video", "the clip of", "a clip of", "clip of", "watch",
    ];

    /// <summary>Pure — mirrors <c>RouterService.videoQuery(from:)</c>: two passes of filler-phrase stripping, then dropping leftover leading connectors.</summary>
    public static string VideoQuery(string prompt)
    {
        var q = $" {prompt.ToLowerInvariant()} ";
        for (var pass = 0; pass < 2; pass++)
            foreach (var strip in VideoQueryStrip)
                q = q.Replace($" {strip} ", " ", StringComparison.OrdinalIgnoreCase);

        var words = new List<string>(q.Split(' ', StringSplitOptions.RemoveEmptyEntries));
        string[] connectors = ["on", "of", "the", "for", "a", "an"];
        while (words.Count > 0 && connectors.Contains(words[0]))
            words.RemoveAt(0);

        var cleaned = string.Join(' ', words).Trim();
        return cleaned.Length == 0 ? prompt.Trim() : cleaned;
    }

    /// <summary>The Windows equivalent of RouterService.swift's <c>openUrl</c> case — extract, validate, open.</summary>
    private static RouteResult OpenUrlReply(string prompt)
    {
        var url = ExtractUrl(prompt);
        if (url is null || !IsUrlSafe(url))
        {
            return new RouteResult(RouteResultKind.NotAvailable,
                "I couldn't find a safe URL to open in that — try naming the exact site.", MiraRoute.OpenUrl);
        }

        try
        {
            BrowserLauncher.Open(url);
            return new RouteResult(RouteResultKind.Reply, $"Opened {url}.", MiraRoute.OpenUrl);
        }
        catch
        {
            return new RouteResult(RouteResultKind.NotAvailable, $"I couldn't open {url}.", MiraRoute.OpenUrl);
        }
    }

    private static readonly string[] OpenPrefixes = ["open ", "go to ", "visit ", "navigate to ", "take me to "];

    /// <summary>Pure — mirrors <c>RouterService.extractURL(from:)</c>: an explicit http(s) URL anywhere in the text, or an "open/go to &lt;domain&gt;" phrasing.</summary>
    public static string? ExtractUrl(string text)
    {
        foreach (var word in text.Split(' '))
        {
            if (Uri.TryCreate(word, UriKind.Absolute, out var explicitUri)
                && (explicitUri.Scheme == "http" || explicitUri.Scheme == "https"))
                return explicitUri.ToString();
        }

        var lower = text.ToLowerInvariant();
        foreach (var prefix in OpenPrefixes)
        {
            var idx = lower.IndexOf(prefix, StringComparison.Ordinal);
            if (idx < 0) continue;

            var remainder = text[(idx + prefix.Length)..].Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
            if (!remainder.Contains('.')) continue;

            var urlStr = remainder.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? remainder : $"https://{remainder}";
            if (Uri.TryCreate(urlStr, UriKind.Absolute, out var built) && !string.IsNullOrEmpty(built.Host)) return built.ToString();
        }
        return null;
    }

    private static readonly string[] UrlShorteners = ["bit.ly", "tinyurl.com", "t.co", "goo.gl", "ow.ly", "buff.ly"];

    /// <summary>Pure — mirrors <c>RouterService.validateURL(_:)</c>: rejects known shorteners and raw IP hosts (both get routed to confirmation on Mac; this port simply declines rather than adding a confirmation round-trip for such a rare case).</summary>
    public static bool IsUrlSafe(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host)) return false;
        if (UrlShorteners.Any(s => uri.Host.EndsWith(s, StringComparison.OrdinalIgnoreCase))) return false;
        return !Regex.IsMatch(uri.Host, @"^\d{1,3}(\.\d{1,3}){3}$");
    }

    /// <summary>The Windows equivalent of RouterService.swift's <c>musicQuery</c> case, but on genuinely better infrastructure than Mac's own: Mac reads a private, undocumented framework (<c>MRMediaRemote</c>); Windows uses the public, documented GSMTC API already built for the Home tab (<see cref="NowPlayingBridge"/>).</summary>
    private static Task<RouteResult> MusicQueryReplyAsync()
    {
        var np = NowPlayingBridge.Current;
        var text = np is { HasContent: true }
            ? $"This is \"{np.Title}\" by {np.Artist}."
            : "Nothing is currently playing.";
        return Task.FromResult(new RouteResult(RouteResultKind.Reply, text, MiraRoute.MusicQuery));
    }

    /// <summary>
    /// The Windows equivalent of RouterService.swift's <c>spotifyControl</c>
    /// case, scoped to basic transport only (play/pause/skip/back) via the
    /// same GSMTC-backed <see cref="NowPlayingBridge"/> as <c>music_query</c>
    /// — genuinely portable since GSMTC already controls whatever session is
    /// currently active, Spotify included, with no AppleScript/app-specific
    /// automation needed. Library actions Mac's own <c>spotifyArgs</c> also
    /// handles (favorite, add-to-playlist, follow artist, playing a specific
    /// named song) need the real Spotify Web API with a per-user OAuth token
    /// — real, bounded work, but a separate one from basic transport, so this
    /// pass declines those explicitly rather than silently no-op'ing a toggle
    /// instead of what was actually asked for.
    /// </summary>
    private static async Task<RouteResult> SpotifyControlReplyAsync(string prompt)
    {
        var action = DetectSpotifyAction(prompt);
        if (action == SpotifyAction.Unsupported)
        {
            return new RouteResult(RouteResultKind.NotAvailable,
                "I can play/pause, skip, and go back, but favoriting, playlists, following an artist, or playing a specific song aren't wired up on Windows yet.",
                MiraRoute.SpotifyControl);
        }

        var np = NowPlayingBridge.Current;
        if (np is null)
        {
            return new RouteResult(RouteResultKind.NotAvailable, "I can't reach media controls right now.", MiraRoute.SpotifyControl);
        }

        string reply;
        switch (action)
        {
            case SpotifyAction.Next:
                await np.NextTrackAsync();
                reply = "Skipped.";
                break;
            case SpotifyAction.Previous:
                await np.PreviousTrackAsync();
                reply = "Went back.";
                break;
            default:
                await np.TogglePlayPauseAsync();
                reply = "Done.";
                break;
        }
        return new RouteResult(RouteResultKind.Reply, reply, MiraRoute.SpotifyControl);
    }

    public enum SpotifyAction { Toggle, Next, Previous, Unsupported }

    /// <summary>Pure — mirrors the basic-transport subset of <c>RouterService.spotifyArgs(from:)</c>; anything needing the real Spotify Web API is flagged <see cref="SpotifyAction.Unsupported"/> rather than guessed at.</summary>
    public static SpotifyAction DetectSpotifyAction(string prompt)
    {
        var lower = prompt.ToLowerInvariant();

        if (lower.Contains("favorite") || lower.Contains("favourite")
            || lower.Contains("like this") || lower.Contains("like the")
            || lower.Contains("save this") || lower.Contains("save the") || lower.Contains("heart this"))
            return SpotifyAction.Unsupported;
        if (lower.Contains("playlist")) return SpotifyAction.Unsupported;
        if (lower.Contains("follow") && (lower.Contains("artist") || lower.Contains("them"))) return SpotifyAction.Unsupported;

        if (lower.Contains("next") || lower.Contains("skip")) return SpotifyAction.Next;
        if (lower.Contains("previous") || lower.Contains("back")) return SpotifyAction.Previous;
        if (lower.Contains("pause")) return SpotifyAction.Toggle;

        var playMatch = Regex.Match(lower, @"\bplay\s+(\S.*)");
        if (playMatch.Success)
        {
            var named = playMatch.Groups[1].Value.Trim();
            if (named.Length > 0 && named is not ("it" or "music" or "spotify" or "something"))
                return SpotifyAction.Unsupported;
        }

        return SpotifyAction.Toggle;
    }

    /// <summary>The Windows equivalent of RouterService.swift's <c>memoryQuery</c> case — mirrors <c>MiraToolService.recallMemories</c> exactly, including its top-8 cap and bullet formatting.</summary>
    private static RouteResult MemoryQueryReply(string prompt)
    {
        var query = ExtractMemoryQuery(prompt);
        var results = MemoryStore.Shared.Recall(query);
        var text = results.Count == 0
            ? $"No memories found for '{query}'."
            : string.Join("\n", results.Take(8).Select(m => $"• {m.Key}: {m.Value}"));
        return new RouteResult(RouteResultKind.Reply, text, MiraRoute.MemoryQuery);
    }

    private static readonly string[] MemoryQueryPrefixes = ["do you remember ", "what do you know about ", "recall ", "what did i tell you about "];

    /// <summary>Pure — mirrors <c>RouterService.extractMemoryQuery(from:)</c>: finds the first matching prefix anywhere in the text (not just at the start), then takes everything after it.</summary>
    public static string ExtractMemoryQuery(string prompt)
    {
        var lower = prompt.ToLowerInvariant();
        foreach (var prefix in MemoryQueryPrefixes)
        {
            var idx = lower.IndexOf(prefix, StringComparison.Ordinal);
            if (idx >= 0) return prompt[(idx + prefix.Length)..].Trim();
        }
        return prompt;
    }

    /// <summary>
    /// The Windows equivalent of RouterService.swift's <c>memoryWrite</c> case
    /// — but a genuine fix, not a straight port. On Mac, this route falls
    /// into the generic <c>agentOrFallback</c> catch-all and never actually
    /// calls <c>MemoryStore.upsert</c> at all; only the voice tool-calling
    /// loop's <c>remember</c> tool does that. Since typed "remember that I
    /// like X" would otherwise silently do nothing (indistinguishable from
    /// every other still-unbuilt route), and this port has no separate
    /// voice-vs-text tool-calling split to explain the asymmetry, this
    /// route calls a small Claude extraction (mirroring <c>LessonAuthor</c>/
    /// <c>SkillAuthor</c>'s JSON-only-reply shape) to pull a key/value/category
    /// out of the prompt and really persists it.
    /// </summary>
    private static async Task<RouteResult> MemoryWriteReplyAsync(string prompt, CancellationToken ct)
    {
        try
        {
            var (key, value, category) = await ExtractMemoryFactAsync(prompt, ct);
            if (key is null || value is null)
            {
                return new RouteResult(RouteResultKind.Reply,
                    "I couldn't tell what to remember from that — try something like \"remember that my favorite editor is VS Code.\"",
                    MiraRoute.MemoryWrite);
            }

            MemoryStore.Shared.Upsert(key, value, category);
            return new RouteResult(RouteResultKind.Reply, $"Remembered: {key} = {value}.", MiraRoute.MemoryWrite);
        }
        catch (Exception ex)
        {
            return new RouteResult(RouteResultKind.NotAvailable, $"I couldn't save that: {ex.Message}", MiraRoute.MemoryWrite);
        }
    }

    private static async Task<(string? Key, string? Value, MemoryCategory Category)> ExtractMemoryFactAsync(string prompt, CancellationToken ct)
    {
        const string jsonShape = """{"key": "snake_case_key", "value": "human readable value", "category": "preference|project|person|fact|goal"}""";
        var body = new JObject
        {
            ["model"] = "claude-haiku-4-5-20251001",
            ["max_tokens"] = 200,
            ["system"] = $"Extract the single fact or preference the user wants remembered. Reply with ONLY a JSON object, no prose, no markdown fences, in exactly this shape: {jsonShape}",
            ["messages"] = new JArray { new JObject { ["role"] = "user", ["content"] = prompt } },
        };
        var raw = await AnthropicProxyClient.SendAsync(body, ct);
        return ParseMemoryFact(raw);
    }

    /// <summary>Pure — parses the model's JSON reply, extracted so it's testable against canned text without a live Claude call. Falls back to <see cref="MemoryCategory.Fact"/> for an unrecognized or missing category rather than failing the whole extraction.</summary>
    public static (string? Key, string? Value, MemoryCategory Category) ParseMemoryFact(string rawReply)
    {
        var start = rawReply.IndexOf('{');
        var end = rawReply.LastIndexOf('}');
        if (start < 0 || end <= start) return (null, null, MemoryCategory.Fact);

        try
        {
            var json = JObject.Parse(rawReply[start..(end + 1)]);
            var key = (string?)json["key"];
            var value = (string?)json["value"];
            if (string.IsNullOrWhiteSpace(key) || string.IsNullOrWhiteSpace(value)) return (null, null, MemoryCategory.Fact);

            var categoryRaw = (string?)json["category"] ?? "fact";
            var category = Enum.TryParse<MemoryCategory>(categoryRaw, ignoreCase: true, out var parsed) ? parsed : MemoryCategory.Fact;
            return (key.Trim(), value.Trim(), category);
        }
        catch
        {
            return (null, null, MemoryCategory.Fact);
        }
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

        var system = BuildSystemPrompt();
        if (!string.IsNullOrEmpty(system)) body["system"] = system;
        return body;
    }

    /// <summary>Joins whatever currently-active prompt biases apply — skill context plus Cat Mode — into one system prompt.</summary>
    private static string BuildSystemPrompt()
    {
        var parts = new List<string>();
        var skillContext = SkillStore.Shared.BuildContext();
        if (!string.IsNullOrEmpty(skillContext)) parts.Add(skillContext);
        var memoryBlock = MemoryStore.Shared.BuildPromptBlock();
        if (!string.IsNullOrEmpty(memoryBlock)) parts.Add(memoryBlock);
        if (PersonalitySettings.CatModeEnabled) parts.Add(PersonalitySettings.CatModeInstruction);
        return string.Join("\n\n", parts);
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
