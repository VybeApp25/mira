using Mira.Contracts.ProfileRow;
using Mira.Windows.Core.Entitlements;
using Xunit;

namespace Mira.Windows.Core.Tests.Entitlements;

/// <summary>
/// Exercises <see cref="EntitlementService.CanForPlan"/> — the pure gating table
/// — directly, rather than through the persisted singleton (see the comment on
/// that method: testing it this way means these tests never touch
/// %LOCALAPPDATA%\Mira\entitlement.json, so they can't corrupt real local state
/// on a dev machine or race with anything else using the singleton).
/// Mirrors EntitlementService.swift's <c>can(_:)</c> switch exactly.
/// </summary>
public class EntitlementServiceTests
{
    [Fact]
    public void Free_CannotRunAgents()
        => Assert.False(EntitlementService.CanForPlan(ProfilePlan.Free, Entitlement.RunAgents));

    [Fact]
    public void Pro_CanRunAgents()
        => Assert.True(EntitlementService.CanForPlan(ProfilePlan.Pro, Entitlement.RunAgents));

    [Fact]
    public void Ultra_CanRunAgents()
        => Assert.True(EntitlementService.CanForPlan(ProfilePlan.Ultra, Entitlement.RunAgents));

    [Theory]
    [InlineData(ProfilePlan.Free)]
    [InlineData(ProfilePlan.Pro)]
    [InlineData(ProfilePlan.Ultra)]
    public void EveryPlan_CanUseVoiceMode(ProfilePlan plan)
        => Assert.True(EntitlementService.CanForPlan(plan, Entitlement.UseVoiceMode));

    [Theory]
    [InlineData(ProfilePlan.Free, false)]
    [InlineData(ProfilePlan.Pro, false)]
    [InlineData(ProfilePlan.Ultra, true)]
    public void BuildApps_IsUltraOnly(ProfilePlan plan, bool expected)
        => Assert.Equal(expected, EntitlementService.CanForPlan(plan, Entitlement.BuildApps));

    [Theory]
    [InlineData(Entitlement.BuildWebsites)]
    [InlineData(Entitlement.UseScreenGuidance)]
    [InlineData(Entitlement.DeepResearch)]
    [InlineData(Entitlement.ContentGeneration)]
    [InlineData(Entitlement.UnlimitedChat)]
    public void ProAndUltraGatedEntitlements_DeniedOnFree(Entitlement entitlement)
        => Assert.False(EntitlementService.CanForPlan(ProfilePlan.Free, entitlement));
}
