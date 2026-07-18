using Mira.Contracts.ProfileRow;

namespace Mira.Windows.Core.Entitlements;

/// <summary>
/// Per-plan derived values — mirrors the computed properties on macOS's
/// <c>SubscriptionPlan</c> enum (Mira/Services/EntitlementService.swift). Deliberately
/// attached as extension methods to the *generated* <see cref="ProfilePlan"/> enum
/// (from shared/contracts/tables/profile-row.schema.json) rather than defining a
/// second, parallel plan enum — the whole point of the shared-contracts work in
/// docs/windows/WINDOWS_ARCHITECTURE.md §5 was to stop exactly this kind of
/// duplication.
/// </summary>
public static class PlanExtensions
{
    public static string DisplayName(this ProfilePlan plan) => plan switch
    {
        ProfilePlan.Free => "Free",
        ProfilePlan.Pro => "Pro",
        ProfilePlan.Ultra => "Ultra",
        _ => plan.ToString(),
    };

    public static int MaxConcurrentAgents(this ProfilePlan plan) => plan switch
    {
        ProfilePlan.Free => 0,
        ProfilePlan.Pro => 2,
        ProfilePlan.Ultra => 5,
        _ => 0,
    };

    /// <summary>
    /// Client-side mirror of the server-side <c>monthly_task_quota()</c> SQL
    /// function (supabase/migrations/20260616120000_task_run_quota.sql) — the
    /// SERVER is authoritative; this is only for an offline fallback / "tasks left"
    /// display, exactly like the Swift original's own doc comment says.
    /// </summary>
    public static int MonthlyTaskRunQuota(this ProfilePlan plan) => plan switch
    {
        ProfilePlan.Free => 5,
        ProfilePlan.Pro => 100,
        ProfilePlan.Ultra => 500,
        _ => 5,
    };
}
