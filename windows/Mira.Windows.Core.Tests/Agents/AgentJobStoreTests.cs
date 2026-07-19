using Mira.Contracts.ProfileRow;
using Mira.Windows.Core.Agents;
using Xunit;

namespace Mira.Windows.Core.Tests.Agents;

/// <summary>Tests the pure CheckCanSubmit gate directly rather than the live singleton's SubmitJob, which would trigger a real Claude API call the moment a submission passes -- same reasoning as ClipboardHistoryStoreTests testing ApplyAdd instead of the disk-touching Add.</summary>
public class AgentJobStoreTests
{
    [Fact]
    public void CheckCanSubmit_FreePlan_IsGated()
    {
        var error = AgentJobStore.CheckCanSubmit(ProfilePlan.Free, currentRunningCount: 0);
        Assert.NotNull(error);
        Assert.Contains("Pro or Ultra", error);
    }

    [Theory]
    [InlineData(ProfilePlan.Pro, 2)]
    [InlineData(ProfilePlan.Ultra, 5)]
    public void CheckCanSubmit_AtConcurrencyCap_IsRejected(ProfilePlan plan, int maxConcurrent)
    {
        var error = AgentJobStore.CheckCanSubmit(plan, currentRunningCount: maxConcurrent);
        Assert.NotNull(error);
        Assert.Contains("limit", error);
    }

    [Theory]
    [InlineData(ProfilePlan.Pro, 1)]
    [InlineData(ProfilePlan.Ultra, 4)]
    public void CheckCanSubmit_UnderConcurrencyCap_IsAllowed(ProfilePlan plan, int currentRunning)
        => Assert.Null(AgentJobStore.CheckCanSubmit(plan, currentRunning));

    [Fact]
    public void CheckCanSubmit_ProAtZeroRunning_IsAllowed()
        => Assert.Null(AgentJobStore.CheckCanSubmit(ProfilePlan.Pro, currentRunningCount: 0));
}
