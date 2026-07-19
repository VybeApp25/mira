using Mira.Windows.Core.Account;
using Mira.Windows.Core.Providers;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Crons;

/// <summary>
/// The Windows equivalent of Mira/Services/CronScheduler.swift — ticks every
/// 60 seconds, fires any due cron's prompt through Claude, and records the
/// result. Mac calls <c>ClaudeService(apiKey:)</c> directly with a locally-held
/// API key; this Windows port has no client-side API key at all (see
/// docs/windows/SECURITY_AND_PRIVACY.md), so this goes through the same
/// <see cref="AnthropicProxyClient"/> every other Claude call in this port
/// uses instead. Started unconditionally at app launch (mirrors
/// <c>CronScheduler.shared.start()</c> in NotchManager.swift, not gated to
/// the Crons tab being open) so crons keep firing while the user is on any
/// other tab.
/// </summary>
public sealed class CronScheduler
{
    private const string Model = "claude-sonnet-4-6";
    private static readonly TimeSpan TickInterval = TimeSpan.FromSeconds(60);

    public static CronScheduler Shared { get; } = new();

    private Timer? _timer;

    private CronScheduler() { }

    public void Start()
    {
        if (_timer is not null) return;
        _timer = new Timer(_ => Tick(), null, TickInterval, TickInterval);
    }

    public void Stop()
    {
        _timer?.Dispose();
        _timer = null;
    }

    private void Tick()
    {
        // Mirrors Mac's own guard (skip the tick entirely if there's no API
        // key to call with) -- here that's "no signed-in session to proxy through."
        if (!AccountService.Shared.IsSignedIn) return;

        foreach (var cron in CronStore.Shared.DueCrons(DateTimeOffset.UtcNow))
            _ = RunNowAsync(cron);
    }

    /// <summary>Fires a single cron's prompt through Claude immediately, independent of the 60s tick — used by <see cref="Tick"/> and available for a manual "run now" action.</summary>
    public static async Task RunNowAsync(MiraCron cron)
    {
        try
        {
            var body = new JObject
            {
                ["model"] = Model,
                ["max_tokens"] = 2000,
                ["messages"] = new JArray { new JObject { ["role"] = "user", ["content"] = cron.Prompt } },
            };
            var result = await AnthropicProxyClient.SendAsync(body);
            CronStore.Shared.RecordRun(cron.Id, result, DateTimeOffset.UtcNow);
        }
        catch (Exception ex)
        {
            CronStore.Shared.RecordRun(cron.Id, $"Error: {ex.Message}", DateTimeOffset.UtcNow);
        }
    }
}
