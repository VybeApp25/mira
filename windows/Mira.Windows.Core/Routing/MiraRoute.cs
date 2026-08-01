namespace Mira.Windows.Core.Routing;

/// <summary>
/// Full port of macOS's <c>MiraRoute</c> enum (Mira/Services/RouterService.swift,
/// lines 7-40) — all 32 cases, kept complete even though most don't have a
/// Windows-side handler yet (see <see cref="RouterHandler"/>). Keeping the full
/// taxonomy matters because the Haiku classifier's system prompt (ported in
/// <see cref="RouterService"/>) needs to correctly identify intent regardless of
/// whether Windows can act on it yet — "recognize but can't do it" is a
/// different, better failure mode than "misclassify because the option didn't exist."
/// </summary>
public enum MiraRoute
{
    LocalResponse,
    ScreenGuidance,
    AgentTask,
    WebsiteBuilder,
    SpotifyControl,
    MusicQuery,
    VideoPlayback,
    OpenUrl,
    MemoryQuery,
    MemoryWrite,
    FileOperation,
    CalendarAction,
    NotesAction,
    ComposioAction,
    StockLookup,
    WeatherLookup,
    WebSearch,
    ImageSearch,
    PlaceSearch,
    MapsQuery,
    ComputerUse,
    FindMyDevices,
    GptQuery,
    ObsidianAction,
    PolymarketQuery,
    EmailTask,
    ResearchTask,
    RepoTask,
    CodexTask,
    ClarificationRequired,
    ConfirmationRequired,
    PermissionRequired,
    HigherModel,
}

public static class MiraRouteExtensions
{
    /// <summary>Matches Swift's <c>MiraRoute.rawValue</c> — the wire format the Haiku classifier returns.</summary>
    public static string ToWireString(this MiraRoute route) => route switch
    {
        MiraRoute.LocalResponse => "local_response",
        MiraRoute.ScreenGuidance => "screen_guidance",
        MiraRoute.AgentTask => "agent_task",
        MiraRoute.WebsiteBuilder => "website_builder",
        MiraRoute.SpotifyControl => "spotify_control",
        MiraRoute.MusicQuery => "music_query",
        MiraRoute.VideoPlayback => "video_playback",
        MiraRoute.OpenUrl => "open_url",
        MiraRoute.MemoryQuery => "memory_query",
        MiraRoute.MemoryWrite => "memory_write",
        MiraRoute.FileOperation => "file_operation",
        MiraRoute.CalendarAction => "calendar_action",
        MiraRoute.NotesAction => "notes_action",
        MiraRoute.ComposioAction => "composio_action",
        MiraRoute.StockLookup => "stock_lookup",
        MiraRoute.WeatherLookup => "weather_lookup",
        MiraRoute.WebSearch => "web_search",
        MiraRoute.ImageSearch => "image_search",
        MiraRoute.PlaceSearch => "place_search",
        MiraRoute.MapsQuery => "maps_query",
        MiraRoute.ComputerUse => "computer_use",
        MiraRoute.FindMyDevices => "findmy_devices",
        MiraRoute.GptQuery => "gpt_query",
        MiraRoute.ObsidianAction => "obsidian_action",
        MiraRoute.PolymarketQuery => "polymarket_query",
        MiraRoute.EmailTask => "email_task",
        MiraRoute.ResearchTask => "research_task",
        MiraRoute.RepoTask => "repo_task",
        MiraRoute.CodexTask => "codex_task",
        MiraRoute.ClarificationRequired => "clarification_required",
        MiraRoute.ConfirmationRequired => "confirmation_required",
        MiraRoute.PermissionRequired => "permission_required",
        MiraRoute.HigherModel => "higher_model",
        _ => throw new ArgumentOutOfRangeException(nameof(route)),
    };

    public static MiraRoute? FromWireString(string s) => s switch
    {
        "local_response" => MiraRoute.LocalResponse,
        "screen_guidance" => MiraRoute.ScreenGuidance,
        "agent_task" => MiraRoute.AgentTask,
        "website_builder" => MiraRoute.WebsiteBuilder,
        "spotify_control" => MiraRoute.SpotifyControl,
        "music_query" => MiraRoute.MusicQuery,
        "video_playback" => MiraRoute.VideoPlayback,
        "open_url" => MiraRoute.OpenUrl,
        "memory_query" => MiraRoute.MemoryQuery,
        "memory_write" => MiraRoute.MemoryWrite,
        "file_operation" => MiraRoute.FileOperation,
        "calendar_action" => MiraRoute.CalendarAction,
        "notes_action" => MiraRoute.NotesAction,
        "composio_action" => MiraRoute.ComposioAction,
        "stock_lookup" => MiraRoute.StockLookup,
        "weather_lookup" => MiraRoute.WeatherLookup,
        "web_search" => MiraRoute.WebSearch,
        "image_search" => MiraRoute.ImageSearch,
        "place_search" => MiraRoute.PlaceSearch,
        "maps_query" => MiraRoute.MapsQuery,
        "computer_use" => MiraRoute.ComputerUse,
        "findmy_devices" => MiraRoute.FindMyDevices,
        "gpt_query" => MiraRoute.GptQuery,
        "obsidian_action" => MiraRoute.ObsidianAction,
        "polymarket_query" => MiraRoute.PolymarketQuery,
        "email_task" => MiraRoute.EmailTask,
        "research_task" => MiraRoute.ResearchTask,
        "repo_task" => MiraRoute.RepoTask,
        "codex_task" => MiraRoute.CodexTask,
        "clarification_required" => MiraRoute.ClarificationRequired,
        "confirmation_required" => MiraRoute.ConfirmationRequired,
        "permission_required" => MiraRoute.PermissionRequired,
        "higher_model" => MiraRoute.HigherModel,
        _ => null,
    };
}
