using System.Text.RegularExpressions;
using Mira.Windows.Core.Auth;
using Mira.Windows.Core.Providers;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Routing;

/// <summary>
/// Port of macOS's <c>RouterService</c> (Mira/Services/RouterService.swift) —
/// the two-tier classifier: a pure, synchronous keyword/regex matcher
/// (<see cref="Route"/>, ported line-for-line from <c>route(prompt:context:)</c>
/// and its ~25 <c>matchesX</c> helpers), gated in front of a Claude Haiku LLM
/// classifier (<see cref="ClassifyIntentAsync"/>/<see cref="HaikuClassifyAsync"/>,
/// ported from <c>classifyIntent</c>/<c>haikuClassify</c>) for prompts the
/// deterministic pass doesn't confidently resolve.
///
/// This class only classifies — it does not execute. See
/// <c>Chat/RouterHandler.cs</c> for what happens with a <see cref="RouteDecision"/>
/// once made, which is where this port's scope narrows sharply: most of the 32
/// routes have no Windows-side handler yet (no Spotify control, no calendar
/// integration, no computer-use, no agent tasks are built on Windows today).
/// </summary>
public sealed class RouterService
{
    public static RouterService Shared { get; } = new();

    // ---- Synchronous classification (pure, no side effects) -----------------
    // Ported directly from RouterService.swift's route(prompt:context:), same
    // priority order, same phrase lists, same confidence values.

    public RouteDecision Route(string prompt, RouterContext context)
    {
        var lower = prompt.ToLowerInvariant();
        var trimmed = prompt.Trim();

        var dangerous = DetectDangerousCommand(lower);
        if (dangerous is not null)
        {
            return new RouteDecision(MiraRoute.ConfirmationRequired, 0.95, "Potentially destructive command",
                ConfirmationSummary: $"This could be destructive: {dangerous}\n\nContinue?", IsDangerous: true);
        }

        if (MatchesMemoryWrite(lower)) return new(MiraRoute.MemoryWrite, 0.88, "Storing a preference or fact");
        if (MatchesMemoryQuery(lower)) return new(MiraRoute.MemoryQuery, 0.88, "Querying stored memory");

        // "What song is this?" must beat the Spotify play matcher.
        if (MatchesMusicQuery(lower)) return new(MiraRoute.MusicQuery, 0.93, "Identify the current track");
        if (MatchesSpotify(lower)) return new(MiraRoute.SpotifyControl, 0.92, "Spotify control");

        var url = ExtractUrl(trimmed);
        if (url is not null)
        {
            if (!ValidateUrl(url))
                return new(MiraRoute.ConfirmationRequired, 0.80, "Suspicious URL detected", ConfirmationSummary: $"Open {url}?");
            return new(MiraRoute.OpenUrl, 0.92, "Open URL in browser");
        }

        if (MatchesVideoRequest(lower)) return new(MiraRoute.VideoPlayback, 0.9, "Open video results instantly");
        if (MatchesComputerUse(lower)) return new(MiraRoute.ComputerUse, 0.88, "Desktop GUI automation request");

        if (MatchesStockLookup(lower)) return new(MiraRoute.StockLookup, 0.90, "Stock quote lookup");
        if (MatchesWeather(lower)) return new(MiraRoute.WeatherLookup, 0.88, "Weather lookup");
        if (MatchesWebSearch(lower)) return new(MiraRoute.WebSearch, 0.85, "Live web search");
        if (MatchesImageSearch(lower)) return new(MiraRoute.ImageSearch, 0.90, "Image search");
        if (MatchesPlaceSearch(lower)) return new(MiraRoute.PlaceSearch, 0.87, "Place / directions lookup");

        if (MatchesGpt(lower)) return new(MiraRoute.GptQuery, 0.93, "GPT/ChatGPT explicit request");
        if (MatchesFindMy(lower)) return new(MiraRoute.FindMyDevices, 0.90, "Find My device query");
        if (MatchesObsidian(lower)) return new(MiraRoute.ObsidianAction, 0.88, "Obsidian vault operation");
        if (MatchesPolymarket(lower)) return new(MiraRoute.PolymarketQuery, 0.90, "Prediction market query");
        if (MatchesEmailTask(lower)) return new(MiraRoute.EmailTask, 0.88, "Email drafting or triage task");
        if (MatchesResearchTask(lower)) return new(MiraRoute.ResearchTask, 0.86, "Research and report generation");
        if (MatchesRepoTask(lower)) return new(MiraRoute.RepoTask, 0.88, "Git / GitHub repository operation");
        if (MatchesCodexTask(lower)) return new(MiraRoute.CodexTask, 0.93, "Explicit Codex CLI agent request");
        if (MatchesMaps(lower)) return new(MiraRoute.MapsQuery, 0.88, "Maps / location / directions query");

        if (MatchesCalendar(lower)) return new(MiraRoute.CalendarAction, 0.85, "Calendar action");
        if (MatchesNotes(lower)) return new(MiraRoute.NotesAction, 0.85, "Notes action");
        if (MatchesFileOperation(lower)) return new(MiraRoute.FileOperation, 0.80, "File system operation");

        if (MatchesScreenGuidance(lower)) return new(MiraRoute.ScreenGuidance, 0.88, "Screen-aware question");

        if (MatchesWebsiteBuilder(lower))
        {
            if (IsWebsiteBuilderAmbiguous(prompt))
                return new(MiraRoute.ClarificationRequired, 0.80, "Need more website details",
                    ClarificationQuestion: "What kind of website, and what should it be called?");
            return new(MiraRoute.WebsiteBuilder, 0.85, "Website builder agent");
        }

        if (MatchesAgentTask(lower)) return new(MiraRoute.AgentTask, 0.75, "Multi-step background task");
        if (MatchesLocalResponse(lower)) return new(MiraRoute.LocalResponse, 0.92, "Simple conversational reply");

        if (IsHighlyAmbiguous(trimmed, context))
            return new(MiraRoute.ClarificationRequired, 0.65, "Request too vague",
                ClarificationQuestion: "I want to help — can you tell me more about what you'd like me to do?");

        return new(MiraRoute.HigherModel, 0.60, "General reasoning via Claude");
    }

    // ---- Two-tier gate: deterministic first, Haiku for the rest --------------

    public async Task<RouteDecision> ClassifyIntentAsync(string prompt, RouterContext context, CancellationToken ct = default)
    {
        var canClassify = !string.IsNullOrEmpty(SupabaseService.CachedAccessToken);
        if (!canClassify) return Route(prompt, context);

        var sync = Route(prompt, context);
        switch (sync.Route)
        {
            case MiraRoute.ConfirmationRequired:
            case MiraRoute.PermissionRequired:
            case MiraRoute.SpotifyControl:
            case MiraRoute.MusicQuery:
            case MiraRoute.VideoPlayback:
            case MiraRoute.OpenUrl:
            case MiraRoute.MemoryWrite:
            case MiraRoute.MemoryQuery:
            case MiraRoute.EmailTask:
            case MiraRoute.ResearchTask:
            case MiraRoute.RepoTask:
            case MiraRoute.CodexTask:
            case MiraRoute.ComputerUse:
            // Not in the Swift original's own bypass list, but the exact same
            // failure mode Mac's own developers already fixed for computerUse
            // ("must not be second-guessed by Haiku... which then told the user
            // 'I can't open YouTube' [when it can]") — confirmed live: Haiku is
            // non-deterministic enough that a deterministic, high-confidence
            // match on an unambiguous factual-recency/live-data phrase ("who won
            // the world cup", a stock ticker, "weather") can still get
            // reclassified down to the tool-less higher_model route, which then
            // apologizes that it has no real-time access instead of actually
            // answering — reproduced directly, not guessed at.
            case MiraRoute.WebSearch:
            case MiraRoute.WeatherLookup:
            case MiraRoute.StockLookup:
                return sync;
        }

        try
        {
            return await HaikuClassifyAsync(prompt, context.RecentTranscript, ct);
        }
        catch
        {
            return sync; // mirrors the Swift original's try?-and-fall-back-to-sync
        }
    }

    private const string HaikuSystemPrompt = """
        You are a routing classifier. Output JSON on one line:
        {"route":"<route>","confidence":<0-1>,"explanation":"<8 words max>"}

        Routes and when to use them:
        - local_response: chitchat, greetings, simple Q&A answerable without tools or live data
        - screen_guidance: explain screen content, "what is this", "what am I looking at"
        - agent_task: background automation, multi-step tasks requiring external tools
        - website_builder: build/create a website or landing page
        - spotify_control: play/pause/skip/volume music, favorite/like the current song, add it to a playlist, follow the artist
        - music_query: "what song is this", "what's playing", "who sings this", "who is this by", "what am I listening to", "name this song" — identify the currently playing track
        - video_playback: the user wants to WATCH a video — "show me the USA highlights", "play the game highlights", "pull up a YouTube video of X", "put on the trailer for Y", "find me a clip of Z", "watch highlights", anything naming YouTube. Route here (not computer_use) so Mira opens the video results instantly instead of driving a slow agent.
        - open_url: open a URL or link
        - memory_query: recall stored preferences or facts about the user
        - memory_write: store a preference, fact, or instruction
        - file_operation: read/write/move/list files on disk
        - calendar_action: schedule, view, or manage calendar events
        - notes_action: Apple Notes create/search/append
        - composio_action: GitHub, Gmail, Notion, Slack, Linear, Vercel, Netlify, Google Drive, Google Docs, Google Sheets, Airtable tasks
        - stock_lookup: current stock price, share price, market quote, ticker symbol lookup
        - weather_lookup: weather, temperature, forecast, how hot/cold, will it rain, do I need a jacket/umbrella
        - web_search: live scores, latest news, current events, "what's happening with", today's results, look it up online, search the web for something with a time-sensitive or factual answer
        - image_search: show images of, pictures of, find photos of
        - place_search: where is, directions to, find nearby, navigate to a location
        - findmy_devices: Find My, list Apple devices, where is my iPhone/Mac/Watch/AirPods
        - gpt_query: ask GPT, ask ChatGPT, use GPT-4, what does ChatGPT say
        - obsidian_action: Obsidian vault, open vault note, search vault, wikilinks, markdown notes in Obsidian
        - polymarket_query: Polymarket, prediction market odds, what are the chances, market probability, will X happen
        - maps_query: nearby, directions to, how far, distance between, find a coffee shop, geocode, navigate to, find nearest
        - computer_use: the user asks Mira to physically DO something on their PC — open an app or website, click, type, play a video, pull something up on screen, show them something in an app, fill out forms, automate, take over the computer
        - email_task: draft email, write email, send email, check inbox, unread emails, triage email, reply to email, email assistant
        - research_task: research report, market research, competitor analysis, web research, write a report on
        - repo_task: pull request, create PR, git commit, git push, code review, review this code, github issues
        - codex_task: use Codex, run Codex, codex CLI, openai codex, codex exec
        - higher_model: analysis, coding, writing, research, complex reasoning

        Action vs. answer: Mira CAN control the PC. If the user wants Mira to PERFORM an action on screen (open / play / click / pull up / show them something in an app or browser), route computer_use. web_search and local_response are only for answering with text. A follow-up that refers back to a previous action request ("why can't you open it?", "just pull it up then") is computer_use.

        Output ONLY the JSON line. No preamble, no markdown fences.
        """;

    private async Task<RouteDecision> HaikuClassifyAsync(string prompt, string? transcript, CancellationToken ct)
    {
        var userContent = transcript is not null
            ? $"Recent conversation:\n{transcript}\n\nClassify this new message: {prompt}"
            : prompt;

        var body = new JObject
        {
            ["model"] = "claude-haiku-4-5-20251001",
            ["max_tokens"] = 80,
            ["system"] = HaikuSystemPrompt,
            ["messages"] = new JArray { new JObject { ["role"] = "user", ["content"] = userContent } },
        };

        var responseText = await AnthropicProxyClient.SendAsync(body, ct);

        var clean = responseText.Trim()
            .Replace("```json", "").Replace("```", "")
            .Trim();

        var parsed = JObject.Parse(clean);
        var routeStr = (string?)parsed["route"] ?? throw new FormatException("haiku-gate-parse");
        var route = MiraRouteExtensions.FromWireString(routeStr) ?? throw new FormatException("haiku-gate-parse");
        var confidence = (double?)parsed["confidence"] ?? 0.5;
        var explanation = (string?)parsed["explanation"] ?? "";

        return new RouteDecision(route, confidence, explanation);
    }

    // ---- Dangerous-command detection -----------------------------------------

    private static readonly (string Trigger, string Summary)[] DangerousPatterns =
    [
        ("rm -rf /", "Delete entire filesystem"),
        ("rm -rf ~", "Delete home directory"),
        ("sudo rm -rf", "Delete files as superuser"),
        ("chmod -r 777 /", "Change root permissions"),
        ("mkfs", "Format a disk"),
        ("dd if=", "Raw disk overwrite"),
        (":(){ :|:& };:", "Fork bomb"),
        ("del /f /s /q", "Delete files recursively (Windows)"), // Windows-equivalent addition — no macOS analog needed, but rm -rf's DOS equivalent belongs in this list
        ("format c:", "Format the C: drive"),
        ("delete everything", "Delete everything in the target location"),
        ("delete all files", "Delete all files"),
        ("delete all ", "Delete all items in a location"),
        ("delete my ", "Delete a user-owned item"),
        ("wipe everything", "Wipe all data"),
        ("wipe all", "Wipe all data"),
        ("erase everything", "Erase all data"),
        ("erase all", "Erase all data"),
        ("overwrite all", "Overwrite all files"),
        ("format my disk", "Format disk"),
        ("format my drive", "Format drive"),
        ("erase my disk", "Erase disk"),
        ("send email to all", "Send email to all users"),
        ("send to all users", "Send to all users"),
        ("email everyone", "Email everyone"),
        ("message everyone", "Message everyone"),
        ("blast everyone", "Message blast to everyone"),
        ("upload my contacts", "Upload contacts to external server"),
        ("share my contacts", "Share personal contacts"),
        ("export my contacts", "Export contacts list"),
    ];

    private static string? DetectDangerousCommand(string lower)
    {
        foreach (var (trigger, summary) in DangerousPatterns)
            if (lower.Contains(trigger)) return summary;
        return null;
    }

    // ---- Detection helpers (pure) — ported 1:1 from RouterService.swift ------

    private static bool MatchesMemoryWrite(string lower)
    {
        if (lower.StartsWith("remember ")) return true;
        return new[] { "from now on", "i prefer ", "my preference is", "i always like",
            "note that i", "keep in mind that", "my name is", "call me ",
            "i want you to know", "store this" }.Any(lower.Contains);
    }

    private static bool MatchesMemoryQuery(string lower) =>
        new[] { "do you remember", "what do you know about me", "what did i tell you",
            "did i mention", "recall what" }.Any(lower.Contains);

    private static bool MatchesSpotify(string lower) => lower.Contains("spotify");

    private static bool MatchesMusicQuery(string lower) => new[]
    {
        "what song is this", "what song is playing", "what's this song", "whats this song",
        "what is this song", "what track is this", "name this song", "name that song",
        "what am i listening to", "what's playing", "whats playing", "what is playing",
        "who is this by", "who's this by", "whos this by", "who sings this",
        "who is this song by", "who's this song by", "who is singing this",
        "what song", "song is this",
    }.Any(lower.Contains);

    private static bool MatchesVideoRequest(string lower)
    {
        if (lower.Contains("youtube")) return true;
        var watchVerbs = new[] { "show me", "play", "pull up", "pull it up", "pull that up",
            "bring up", "put on", "throw on", "watch", "let me see",
            "i want to watch", "i wanna watch", "find me" };
        var videoNouns = new[] { "highlights", "the video", "a video", "music video",
            "trailer", "the clip", "a clip", "full match", "full game", "the game" };
        return watchVerbs.Any(lower.Contains) && videoNouns.Any(lower.Contains);
    }

    private static bool MatchesCalendar(string lower) => new[]
    {
        "calendar", "add event", "create event", "what's on my schedule", "upcoming events",
        "set a reminder", "schedule a meeting", "book a time",
    }.Any(lower.Contains);

    private static bool MatchesNotes(string lower) => new[]
    {
        "save to notes", "create a note", "add to notes", "write this down",
        "take a note", "make a note", "note this",
    }.Any(lower.Contains);

    private static bool MatchesFileOperation(string lower) => new[]
    {
        "create a file", "make a file", "read the file", "list files", "list directory",
        "find the file", "move the file", "copy the file", "delete the file",
        "show me files", "what files are",
    }.Any(lower.Contains);

    private static readonly Regex TickerPattern = new(@"\$[a-z]{1,5}\b", RegexOptions.Compiled);

    private static bool MatchesStockLookup(string lower)
    {
        if (TickerPattern.IsMatch(lower)) return true;
        var priceTerms = new[] { "stock price", "stock quote", "share price", "trading at", "what is the price of",
            "how much is", "price of", "stock of", "how is" };
        var stockWords = new[] { "stock", "shares", "trading", "$" };
        var explicitTerms = new[] { "stock price", "stock quote", "share price", "ticker" };
        return (priceTerms.Any(lower.Contains) && stockWords.Any(lower.Contains)) || explicitTerms.Any(lower.Contains);
    }

    private static bool MatchesImageSearch(string lower) => new[]
    {
        "show me images of", "images of ", "pictures of ", "show pictures of",
        "find images of", "search images", "image search",
    }.Any(lower.Contains);

    private static bool MatchesWeather(string lower) => new[]
    {
        "weather", "temperature", "forecast", "how hot", "how cold", "how warm",
        "will it rain", "is it raining", "going to rain", "do i need an umbrella",
        "do i need a jacket", "is it snowing", "how's it outside", "hows it outside",
    }.Any(lower.Contains);

    private static readonly Regex ScoresWordPattern = new(@"\bscores?\b", RegexOptions.Compiled);
    private static readonly Regex NewsWordPattern = new(@"\bnews\b", RegexOptions.Compiled);

    private static bool MatchesWebSearch(string lower)
    {
        var phrases = new[] { "search the web", "search online", "search for", "look it up", "look up online",
            "google ", "live score", "the score", "latest news", "sports news", "current news",
            "current score", "who won", "world cup", "headlines", "what's happening with",
            "whats happening with", "what's the latest", "whats the latest", "today's results", "todays results" };
        return phrases.Any(lower.Contains) || ScoresWordPattern.IsMatch(lower) || NewsWordPattern.IsMatch(lower);
    }

    private static bool MatchesGpt(string lower) => new[]
    {
        "ask gpt", "ask chatgpt", "use gpt", "use chatgpt", "ask openai",
        "gpt-4", "gpt4", "chatgpt", "via gpt", "with gpt",
        "what does gpt say", "what does chatgpt say",
    }.Any(lower.Contains);

    private static bool MatchesMaps(string lower)
    {
        var nearbyTerms = new[] { "nearby", "near me", "closest", "find a ", "find the nearest",
            "coffee shop", "restaurant near", "directions to", "how far is",
            "distance from", "distance between", "route to", "route from",
            "navigate to", "what's around", "geocode", "what is the address of" };
        var placeTerms = new[] { "find nearby", "find a nearby" };
        return nearbyTerms.Any(lower.Contains) || placeTerms.Any(lower.Contains);
    }

    private static bool MatchesComputerUse(string lower)
    {
        var direct = new[]
        {
            "click on", "type into", "type in the", "open the app", "drive the app",
            "automate this", "fill out the form", "use my mouse", "use computer use",
            "control my mac", "control my pc", "control my computer", "operate the", "screenshot my desktop",
            "click the button", "click submit", "scroll down in",
            "do it for me", "do this for me", "do that for me", "take over", "you do it",
            "pull it up", "pull that up", "pull this up", "pull up the", "pull up a",
            "bring it up", "bring that up", "bring up the",
            "play the video", "play a video", "play that video", "click a video",
            "click the video", "play the highlights", "show me the highlights",
            "open youtube", "go to youtube", "go on youtube",
            "open the browser", "open my browser", "open a browser",
        };
        if (direct.Any(lower.Contains)) return true;

        var verbs = new[] { "show me", "open ", "play ", "watch ", "put on", "pull up", "bring up", "go to ", "go on " };
        var surfaces = new[] { "youtube", "browser", "chrome", "safari", "netflix",
            "twitch", "instagram", "tiktok", "reddit", "the video", "a video" };
        return verbs.Any(lower.Contains) && surfaces.Any(lower.Contains);
    }

    private static bool MatchesObsidian(string lower) => new[]
    {
        "obsidian", "my vault", "vault note", "open vault", "search vault", "wikilink", "[[",
    }.Any(lower.Contains);

    private static bool MatchesPolymarket(string lower) => new[]
    {
        "polymarket", "prediction market", "prediction odds",
        "market odds", "what are the odds", "what are the chances",
        "will it happen", "market probability",
    }.Any(lower.Contains);

    private static bool MatchesFindMy(string lower) => new[]
    {
        "find my", "findmy", "where is my iphone", "where is my mac", "where is my airpods",
        "where is my watch", "where is my ipad", "where are my devices",
        "track my phone", "track my device", "locate my device",
        "find my device", "find my phone", "list my devices", "my apple devices",
    }.Any(lower.Contains);

    private static bool MatchesPlaceSearch(string lower) => new[]
    {
        "where is ", "directions to ", "how do i get to ", "navigate to ",
        "find a nearby", "find nearby", "nearest ",
    }.Any(lower.Contains);

    private static bool MatchesScreenGuidance(string lower) => new[]
    {
        "what am i looking at", "what's on my screen", "what is on my screen",
        "read my screen", "look at my screen", "analyze my screen", "analyze this screen",
        "what do you see", "explain this", "translate this", "summarize this",
        "where do i click", "show me where", "what's open on",
        "describe what's on", "what's on screen",
        "can you see", "see my screen", "do you see", "can you view",
        "view my screen", "you see my", "see the screen", "see what's",
        "see what i", "show my screen", "what's happening on",
        "look at what", "see this", "what is this",
    }.Any(lower.Contains);

    private static bool MatchesWebsiteBuilder(string lower)
    {
        var buildVerbs = new[] { "build", "create", "make", "design", "develop" };
        var webNouns = new[] { "website", "landing page", "web page" };
        return buildVerbs.Any(lower.Contains) && webNouns.Any(lower.Contains);
    }

    private static bool IsWebsiteBuilderAmbiguous(string prompt)
    {
        var lower = prompt.ToLowerInvariant();
        var specificTypes = new[] { "saas", "agency", "ecommerce", "e-commerce", "portfolio",
            "restaurant", "shop", "store", "blog", "fintech", "healthcare",
            "nonprofit", "consulting", "roofing", "legal", "medical",
            "fitness", "real estate", "startup", "corporate" };
        var hasType = specificTypes.Any(lower.Contains);
        var hasName = lower.Contains("called ") || lower.Contains("named ")
            || (lower.Contains(" for ") && !lower.Contains("for my ") && !lower.Contains("for a ") && !lower.Contains("for our "));
        return !(hasType && hasName);
    }

    private static bool MatchesEmailTask(string lower) => new[]
    {
        "draft email", "write email", "send email", "reply to email", "compose email",
        "email to ", "email draft", "check my inbox", "check inbox", "check email",
        "unread emails", "my emails", "triage email", "triage my inbox",
        "sort my emails", "reply to this email", "respond to email",
        "write a reply", "email assistant",
    }.Any(lower.Contains);

    private static bool MatchesResearchTask(string lower) => new[]
    {
        "research report", "market research", "competitor analysis",
        "find information about", "write a report on", "market brief",
        "compile research", "web research", "source-backed",
        "do research on", "research about", "research the",
    }.Any(lower.Contains);

    private static bool MatchesRepoTask(string lower) => new[]
    {
        "pull request", "create pr", "open pr", "merge pr", "review pr",
        "git commit", "git push", "git status", "git diff", "git log",
        "code review", "review this code", "review this pr",
        "create a branch", "checkout branch", "close issue", "open issue",
        "github issues", "push to github", "push to main",
        "commit this", "create a commit",
    }.Any(lower.Contains);

    private static bool MatchesCodexTask(string lower) =>
        new[] { "use codex", "run codex", "codex cli", "openai codex", "codex exec", "codex agent" }.Any(lower.Contains)
        || (lower.Contains("codex") && new[] { "fix ", "build ", "refactor", "write " }.Any(lower.Contains));

    private static bool MatchesAgentTask(string lower) => new[]
    {
        "research ", "write a report", "write a full ", "write a complete ",
        "create a plan", "build a plan", "build me a complete", "create a complete",
        "help me plan", "help me build", "help me create", "help me write",
        "help me automate", "automate my ", "set up automation",
        "generate a ", "draft a ", "work on ", "analyze ", "look into ",
        "investigate ", "find information about", "compile a list",
        "create a funnel", "build a funnel", "set up a funnel",
        "give me a summary", "summarize the ", "make me a plan",
        "build a strategy", "create a strategy",
    }.Any(lower.Contains);

    private static readonly char[] PunctuationToTrim = "!.,?;:".ToCharArray();

    private static bool MatchesLocalResponse(string lower)
    {
        if (lower.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length > 6) return false;
        var normalized = lower.Trim(PunctuationToTrim);
        var exact = new HashSet<string> { "hi", "hello", "hey", "thanks", "thank you", "ok", "okay",
            "got it", "sounds good", "cool", "perfect", "great", "awesome",
            "bye", "goodbye", "nice", "yep", "nope", "yes", "no" };
        if (exact.Contains(normalized)) return true;
        return new[] { "who are you", "what are you", "what can you do", "hi mira", "hello mira", "hey mira" }
            .Any(normalized.StartsWith);
    }

    private static bool IsHighlyAmbiguous(string text, RouterContext context)
    {
        var lower = text.ToLowerInvariant();
        var normalized = lower.Trim(PunctuationToTrim);

        var vagueExact = new HashSet<string>
        {
            "do it", "that", "it", "this", "fix it", "fix that", "the thing", "go",
            "fix this", "do it for me", "make it better", "make it work", "make this better",
            "just do it", "handle it", "take care of it", "help", "help me",
        };
        if (vagueExact.Contains(normalized)) return true;

        var vagueStarts = new[]
        {
            "idk", "idk just", "not sure just",
            "make me something", "make something", "make me a thing",
            "build something", "create something", "design something",
            "create an app", "build an app", "make an app",
            "design a logo", "create a logo", "make a logo",
            "make it", "fix it", "do something",
        };
        if (vagueStarts.Any(s => normalized == s || normalized.StartsWith(s + " "))) return true;

        if (lower.Contains("just help me with") || lower.Contains("idk just")) return true;

        return text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length <= 2 && context.RecentMessageCount == 0;
    }

    // ---- URL extraction/validation --------------------------------------------

    public static string? ExtractUrl(string text)
    {
        var words = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        foreach (var w in words)
        {
            if (Uri.TryCreate(w, UriKind.Absolute, out var explicitUri)
                && (explicitUri.Scheme == "http" || explicitUri.Scheme == "https"))
                return explicitUri.ToString();
        }

        var openPrefixes = new[] { "open ", "go to ", "visit ", "navigate to ", "take me to " };
        var lowerText = text.ToLowerInvariant();
        foreach (var prefix in openPrefixes)
        {
            var idx = lowerText.IndexOf(prefix, StringComparison.Ordinal);
            if (idx < 0) continue;
            var remainder = text[(idx + prefix.Length)..].Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
            if (!remainder.Contains('.')) continue;
            var urlStr = remainder.StartsWith("http") ? remainder : $"https://{remainder}";
            if (Uri.TryCreate(urlStr, UriKind.Absolute, out var uri) && !string.IsNullOrEmpty(uri.Host)) return uri.ToString();
        }
        return null;
    }

    private static readonly Regex IpPattern = new(@"^\d{1,3}(\.\d{1,3}){3}$", RegexOptions.Compiled);

    private static bool ValidateUrl(string urlString)
    {
        if (!Uri.TryCreate(urlString, UriKind.Absolute, out var url) || string.IsNullOrEmpty(url.Host)) return false;
        var shorteners = new[] { "bit.ly", "tinyurl.com", "t.co", "goo.gl", "ow.ly", "buff.ly" };
        if (shorteners.Any(url.Host.EndsWith)) return false;
        if (IpPattern.IsMatch(url.Host)) return false;
        return true;
    }

    // ---- Execution helpers used by RouterHandler ------------------------------

    /// <summary>
    /// Canned, zero-latency replies for genuine small talk plus anything
    /// answerable from the local system clock alone (real data, not a model
    /// guess). Returns <c>null</c> when the prompt doesn't match anything
    /// specific — callers MUST treat <c>null</c> as "escalate to a real model,"
    /// not as license to print a placeholder. This used to fall through to a
    /// bare "Got it." for anything unmatched (e.g. "what day is it"), which is
    /// exactly what looked like the assistant "not pulling any intelligence" —
    /// see <see cref="Chat.RouterHandler"/>'s local_response handling for the fix.
    /// </summary>
    public static string? LocalReply(string prompt)
    {
        var lower = prompt.ToLowerInvariant().Trim(PunctuationToTrim);
        if (lower.StartsWith("hi") || lower.StartsWith("hello") || lower.StartsWith("hey"))
            return "Hi! I'm Mira — your Windows companion. What can I help you with?";
        if (lower.Contains("who are you") || lower.Contains("what are you"))
            return "I'm Mira. On Windows today I can chat and answer questions — more capabilities are on the way.";
        if (lower.Contains("what can you do"))
            return "Right now: text chat via Claude and GPT. Voice, screen awareness, and desktop automation are coming in later phases.";
        if (lower.Contains("thanks") || lower.Contains("thank you")) return "Happy to help!";
        if (lower.Contains("bye") || lower.Contains("goodbye")) return "I'll be here when you need me.";

        var dateTimeReply = TryDateTimeReply(lower);
        if (dateTimeReply is not null) return dateTimeReply;

        return null;
    }

    /// <summary>
    /// Answers date/day/time questions from the real local system clock —
    /// genuinely "answerable without tools or live data" (it's on the machine),
    /// so it belongs in local_response rather than a model round-trip, but only
    /// when we can answer it correctly rather than guessing.
    /// </summary>
    private static string? TryDateTimeReply(string lower)
    {
        var now = DateTime.Now;
        var wantsDate = lower.Contains("what day") || lower.Contains("what's the date") || lower.Contains("whats the date")
            || lower.Contains("today's date") || lower.Contains("todays date") || lower.Contains("current date")
            || (lower.Contains("what") && lower.Contains("date") && lower.Contains("today"));
        var wantsTime = lower.Contains("what time") || lower.Contains("current time") || lower.Contains("time is it");

        if (wantsDate && wantsTime)
            return $"It's {now:dddd, MMMM d, yyyy} and the time is {now:h:mm tt}.";
        if (wantsDate)
            return $"Today is {now:dddd, MMMM d, yyyy}.";
        if (wantsTime)
            return $"It's {now:h:mm tt}.";
        return null;
    }

    public static string ExtractMemoryQuery(string prompt)
    {
        var lower = prompt.ToLowerInvariant();
        foreach (var prefix in new[] { "do you remember ", "what do you know about ", "recall ", "what did i tell you about " })
        {
            var idx = lower.IndexOf(prefix, StringComparison.Ordinal);
            if (idx >= 0) return prompt[(idx + prefix.Length)..].Trim();
        }
        return prompt;
    }
}
