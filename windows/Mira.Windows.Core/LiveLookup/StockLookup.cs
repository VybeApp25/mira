using System.Net.Http.Headers;
using System.Text.RegularExpressions;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.LiveLookup;

/// <summary>
/// The Windows equivalent of Mira/Services/ChatWidgetService.swift's
/// <c>fetchStock(query:)</c>. Mac's original hits Yahoo Finance's
/// <c>v7/finance/quote</c> endpoint — confirmed dead during live
/// verification of this port (returns a flat 401 for every symbol as of
/// 2026-07-19; Yahoo now requires a cookie+crumb handshake that endpoint
/// never needed before). Rather than port a call to an endpoint proven not
/// to work, this uses Yahoo's sibling <c>v8/finance/chart</c> endpoint
/// instead — same provider, still fully keyless, confirmed live and
/// returning the same <c>regularMarketPrice</c>/<c>previousClose</c>/
/// <c>shortName</c> fields needed for an equivalent spoken answer. Mac
/// renders its result as a rich widget card in <c>IslandChatView</c> and
/// only falls back to text when that widget can't build; this port answers
/// with text directly, since Windows chat has no equivalent widget surface yet.
/// </summary>
public static class StockLookup
{
    private static readonly HttpClient Http = new();

    public static async Task<string?> LookupAsync(string prompt, CancellationToken ct = default)
    {
        var symbol = ExtractTicker(prompt);
        if (symbol.Length == 0) return null;

        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, $"https://query1.finance.yahoo.com/v8/finance/chart/{symbol}");
            req.Headers.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
            using var resp = await Http.SendAsync(req, ct);
            if (!resp.IsSuccessStatusCode) return null;

            var json = JObject.Parse(await resp.Content.ReadAsStringAsync(ct));
            var meta = json["chart"]?["result"]?.FirstOrDefault()?["meta"];
            if (meta is null) return null;

            var name = (string?)meta["shortName"] ?? symbol;
            var price = (double?)meta["regularMarketPrice"];
            if (price is null) return null;
            var previousClose = (double?)meta["previousClose"] ?? price.Value;
            var change = price.Value - previousClose;
            var changePercent = previousClose != 0 ? change / previousClose * 100 : 0;
            var currency = (string?)meta["currency"] ?? "USD";
            var sign = change >= 0 ? "+" : "";

            return $"{name} ({symbol}) is at {price:0.##} {currency}, {sign}{change:0.##} ({sign}{changePercent:0.##}%).";
        }
        catch
        {
            return null;
        }
    }

    private static readonly string[] TickerPatterns =
    [
        @"\$([A-Z]{1,5})\b",
        @"\b([A-Z]{1,5})\s+(?:STOCK|SHARES|PRICE|QUOTE)\b",
        @"(?:PRICE\s+OF|STOCK\s+OF|QUOTE\s+FOR|TICKER)\s+([A-Z]{1,5})\b",
    ];

    /// <summary>Pure — mirrors <c>ChatWidgetService.extractTicker(from:)</c>'s three regex patterns, checked in the same order.</summary>
    public static string ExtractTicker(string prompt)
    {
        var upper = prompt.ToUpperInvariant();
        foreach (var pattern in TickerPatterns)
        {
            var match = Regex.Match(upper, pattern);
            if (match.Success && match.Groups.Count > 1) return match.Groups[1].Value;
        }
        return "";
    }
}
