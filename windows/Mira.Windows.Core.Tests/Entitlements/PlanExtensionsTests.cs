using Mira.Contracts.ProfileRow;
using Mira.Windows.Core.Entitlements;
using Xunit;

namespace Mira.Windows.Core.Tests.Entitlements;

/// <summary>
/// Pins the per-plan derived values against the confirmed macOS source
/// (Mira/Services/EntitlementService.swift's <c>SubscriptionPlan</c> computed
/// properties), so a future edit can't silently drift from parity.
/// </summary>
public class PlanExtensionsTests
{
    [Theory]
    [InlineData(ProfilePlan.Free, 0)]
    [InlineData(ProfilePlan.Pro, 2)]
    [InlineData(ProfilePlan.Ultra, 5)]
    public void MaxConcurrentAgents_MatchesSwiftSource(ProfilePlan plan, int expected)
        => Assert.Equal(expected, plan.MaxConcurrentAgents());

    [Theory]
    [InlineData(ProfilePlan.Free, 5)]
    [InlineData(ProfilePlan.Pro, 100)]
    [InlineData(ProfilePlan.Ultra, 500)]
    public void MonthlyTaskRunQuota_MatchesSwiftSource(ProfilePlan plan, int expected)
        => Assert.Equal(expected, plan.MonthlyTaskRunQuota());

    [Theory]
    [InlineData(ProfilePlan.Free, "Free")]
    [InlineData(ProfilePlan.Pro, "Pro")]
    [InlineData(ProfilePlan.Ultra, "Ultra")]
    public void DisplayName_MatchesSwiftSource(ProfilePlan plan, string expected)
        => Assert.Equal(expected, plan.DisplayName());

    [Theory]
    [InlineData(ProfilePlan.Free, 5)]
    [InlineData(ProfilePlan.Pro, 5)]
    [InlineData(ProfilePlan.Ultra, int.MaxValue)]
    public void MaxShelfItems_MatchesSwiftSource(ProfilePlan plan, int expected)
        => Assert.Equal(expected, plan.MaxShelfItems());
}
