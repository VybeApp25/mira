using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.LiveLookup;

/// <summary>
/// The Windows equivalent of Mira/Services/WeatherService.swift's
/// <c>lookup(city:)</c> — a spoken-text weather summary from
/// <a href="https://wttr.in">wttr.in</a>, a free, keyless public HTTP API (no
/// auth of any kind, client-side or proxied). Mac also opens its native
/// Weather app via Accessibility automation as a parallel visible action;
/// that half is Mac-only (there's no Windows Weather app to drive the same
/// way) and isn't ported — only the spoken/text answer, which is the part
/// that actually answers the user's question.
/// </summary>
public static class WeatherLookup
{
    private static readonly HttpClient Http = new();

    public static async Task<string?> LookupAsync(string? city, CancellationToken ct = default)
    {
        var path = "https://wttr.in/";
        if (!string.IsNullOrEmpty(city)) path += Uri.EscapeDataString(city);
        path += "?format=j1";

        try
        {
            using var resp = await Http.GetAsync(path, ct);
            if (!resp.IsSuccessStatusCode) return null;

            var json = JObject.Parse(await resp.Content.ReadAsStringAsync(ct));
            var current = (json["current_condition"] as JArray)?.FirstOrDefault();
            if (current is null) return null;

            var tempF = (string?)current["temp_F"] ?? "--";
            var feels = (string?)current["FeelsLikeF"] ?? tempF;
            var desc = (string?)(current["weatherDesc"] as JArray)?.FirstOrDefault()?["value"] ?? "clear";
            var today = (json["weather"] as JArray)?.FirstOrDefault();
            var maxF = (string?)today?["maxtempF"] ?? "--";
            var minF = (string?)today?["mintempF"] ?? "--";
            var area = (json["nearest_area"] as JArray)?.FirstOrDefault();
            var apiArea = (string?)(area?["areaName"] as JArray)?.FirstOrDefault()?["value"];
            // Prefer the city the user actually asked for, matching Mac's own
            // reasoning: wttr.in's "nearest area" can be a different, less
            // recognizable name than what was asked for.
            var place = city ?? apiArea ?? "your area";

            return $"It's {tempF}°F and {desc.ToLowerInvariant()} in {place}, feels like {feels}°. "
                 + $"Today's high {maxF}°, low {minF}°.";
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Pure — pulls a city out of "weather in Atlanta" style prompts, mirroring
    /// <c>RouterService.extractCity(from:)</c> exactly (including its loop-
    /// without-break structure for stripping trailing time words). Returns
    /// null for "current location" prompts — Mac falls back to the Mac's real
    /// GPS coordinate in that case; this port instead passes no location
    /// segment to wttr.in at all, letting the API's own IP-based geolocation
    /// answer (the same fallback Mac's own code takes when GPS is denied),
    /// rather than adding a new Windows location-permission dependency for
    /// what's already just wttr.in's fallback path on Mac too.
    /// </summary>
    public static string? ExtractCity(string prompt)
    {
        var lower = prompt.ToLowerInvariant();
        var idx = lower.IndexOf(" in ", StringComparison.Ordinal);
        if (idx < 0) return null;

        var city = prompt[(idx + 4)..].Trim().Trim('?', '.', '!', ',');
        string[] suffixes = [" today", " right now", " tonight", " tomorrow", " this week", " this weekend", " now"];
        foreach (var suffix in suffixes)
        {
            if (city.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
                city = city[..^suffix.Length].TrimEnd();
        }

        return city.Length == 0 ? null : city;
    }
}
