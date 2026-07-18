using Mira.Contracts.ProfileRow;
using Mira.Windows.Core.Auth;
using Mira.Windows.Core.Storage;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Entitlements;

/// <summary>
/// The Windows equivalent of macOS's <c>EntitlementService</c>
/// (Mira/Services/EntitlementService.swift). Same contract, restated here because
/// it matters for how this class is used: <see cref="Plan"/> is a **client-side
/// cache for UX only** — <c>profiles.plan</c> on the server (Stripe-webhook-updated)
/// is the actual source of truth, and every real enforcement decision (token
/// quotas, voice caps, task-run caps) happens server-side regardless of what this
/// class reports. See docs/windows/SECURITY_AND_PRIVACY.md §3.
///
/// Deliberately narrower than the Swift original for this milestone: no
/// <c>pollForUpgrade</c> (there's no Stripe checkout flow wired up on Windows yet
/// to poll after — add it alongside that, not before).
/// </summary>
public sealed class EntitlementService
{
    private const string SettingsFileName = "entitlement.json";

    public static EntitlementService Shared { get; } = new();

    public ProfilePlan Plan { get; private set; } = ProfilePlan.Free;

    public event Action<ProfilePlan>? PlanChanged;

    private EntitlementService()
    {
        Plan = LoadCachedPlan() ?? ProfilePlan.Free;
    }

    public bool Can(Entitlement entitlement) => CanForPlan(Plan, entitlement);

    /// <summary>
    /// The actual gating logic, factored out as a pure function so it's testable
    /// without mutating this class's persisted singleton state (UpdatePlan writes
    /// to disk — a unit test shouldn't do that to exercise a pure decision table).
    /// Mirrors <c>EntitlementService.can(_:)</c> in Mira/Services/EntitlementService.swift.
    /// </summary>
    public static bool CanForPlan(ProfilePlan plan, Entitlement entitlement) => entitlement switch
    {
        Entitlement.UseVoiceMode => true,
        Entitlement.BuildApps => plan == ProfilePlan.Ultra,
        Entitlement.RunAgents or Entitlement.BuildWebsites or Entitlement.UseScreenGuidance
            or Entitlement.DeepResearch or Entitlement.ContentGeneration or Entitlement.UnlimitedChat
            => plan is ProfilePlan.Pro or ProfilePlan.Ultra,
        _ => false,
    };

    public int MaxConcurrentAgents => Plan.MaxConcurrentAgents();

    /// <summary>Fetches <c>profiles.plan</c> from Supabase and applies it locally. Best-effort — mirrors the Swift original's <c>try?</c> fire-and-forget semantics.</summary>
    public async Task FetchAndApplyPlanAsync(CancellationToken ct = default)
    {
        try
        {
            var json = await SupabaseService.Shared.AuthedRequestAsync(
                "/rest/v1/profiles?select=plan&limit=1", HttpMethod.Get, ct: ct);
            var rows = JArray.Parse(json);
            var raw = (string?)rows.FirstOrDefault()?["plan"];
            if (raw is not null && TryParsePlan(raw, out var plan)) UpdatePlan(plan);
        }
        catch
        {
            // Best-effort — a failed fetch just means the cached plan (possibly
            // stale) keeps being used for UX until the next successful fetch.
        }
    }

    /// <summary>Called when the backend confirms a subscription change.</summary>
    public void UpdatePlan(ProfilePlan plan)
    {
        Plan = plan;
        Persist(plan);
        PlanChanged?.Invoke(plan);
    }

    private static bool TryParsePlan(string raw, out ProfilePlan plan)
    {
        switch (raw)
        {
            case "free": plan = ProfilePlan.Free; return true;
            case "pro": plan = ProfilePlan.Pro; return true;
            case "ultra": plan = ProfilePlan.Ultra; return true;
            default: plan = ProfilePlan.Free; return false;
        }
    }

    private static void Persist(ProfilePlan plan)
    {
        var json = new JObject { ["plan"] = plan.ToString().ToLowerInvariant() }.ToString(Newtonsoft.Json.Formatting.None);
        File.WriteAllText(LocalAppData.PathFor(SettingsFileName), json);
    }

    private static ProfilePlan? LoadCachedPlan()
    {
        var path = LocalAppData.PathFor(SettingsFileName);
        if (!File.Exists(path)) return null;
        try
        {
            var raw = (string?)JObject.Parse(File.ReadAllText(path))["plan"];
            return raw is not null && TryParsePlan(raw, out var plan) ? plan : null;
        }
        catch (Newtonsoft.Json.JsonException)
        {
            return null;
        }
    }
}
