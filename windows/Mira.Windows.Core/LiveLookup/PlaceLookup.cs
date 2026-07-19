using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.LiveLookup;

public sealed record PlaceResult(string Name, string Address, double Lat, double Lon);

/// <summary>
/// The Windows equivalent of Mira/Services/ChatWidgetService.swift's
/// <c>fetchPlace(query:)</c> — OpenStreetMap's Nominatim geocoder, a free,
/// keyless public HTTP API (Nominatim's usage policy just requires a real
/// User-Agent, not an API key). Shared by both <c>place_search</c> and
/// <c>maps_query</c> on this port: Mac's own Python maps skill
/// (<c>maps.py</c>) hits this exact same Nominatim/OSRM combination for its
/// geocoding half, so rather than standing up a second near-identical
/// client, both routes reuse this one. Full OSRM turn-by-turn routing
/// ("directions from X to Y") is not ported this pass — see
/// docs/windows/IMPLEMENTATION_PLAN.md.
/// </summary>
public static class PlaceLookup
{
    private static readonly HttpClient Http = new();

    public static async Task<PlaceResult?> LookupAsync(string query, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(query)) return null;

        try
        {
            var escaped = Uri.EscapeDataString(query);
            using var req = new HttpRequestMessage(HttpMethod.Get,
                $"https://nominatim.openstreetmap.org/search?q={escaped}&format=json&limit=1&addressdetails=1");
            req.Headers.UserAgent.ParseAdd("Mira/1.0 Windows");
            using var resp = await Http.SendAsync(req, ct);
            if (!resp.IsSuccessStatusCode) return null;

            var results = JArray.Parse(await resp.Content.ReadAsStringAsync(ct));
            var first = results.FirstOrDefault();
            if (first is null) return null;

            var lat = double.TryParse((string?)first["lat"], out var la) ? la : 0;
            var lon = double.TryParse((string?)first["lon"], out var lo) ? lo : 0;
            var display = (string?)first["display_name"] ?? query;
            var addr = first["address"] as JObject ?? new JObject();

            var name = (string?)addr["amenity"]
                ?? (string?)addr["shop"]
                ?? (string?)addr["tourism"]
                ?? (string?)addr["leisure"]
                ?? (string?)addr["building"]
                ?? display.Split(", ").FirstOrDefault()
                ?? query;

            var road = (string?)addr["road"] ?? "";
            var city = (string?)addr["city"] ?? (string?)addr["town"] ?? (string?)addr["village"] ?? "";
            var state = (string?)addr["state"] ?? "";
            var country = (string?)addr["country"] ?? "";
            var full = string.Join(", ", new[] { road, city, state, country }.Where(s => s.Length > 0));

            return new PlaceResult(name, full.Length == 0 ? display : full, lat, lon);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Pure — mirrors <c>ChatWidgetService.placeQuery(from:)</c>'s filler-stripping.</summary>
    public static string ExtractPlaceQuery(string prompt)
    {
        var lower = prompt.ToLowerInvariant();
        string[] strips = ["where is ", "find ", "locate ", "directions to ", "how do i get to ", "navigate to ", "map of ", "find a "];
        foreach (var strip in strips)
        {
            if (lower.StartsWith(strip, StringComparison.Ordinal))
                return prompt[strip.Length..].Trim();
        }
        return prompt;
    }
}
