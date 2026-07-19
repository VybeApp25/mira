using Mira.Windows.Core.Agents;
using Xunit;

namespace Mira.Windows.Core.Tests.Agents;

public class AgentJobTests
{
    [Theory]
    [InlineData("research the impact of remote work on productivity", AgentJobType.DeepResearch)]
    [InlineData("investigate our top 3 competitors", AgentJobType.DeepResearch)]
    [InlineData("look into why the build is slow", AgentJobType.DeepResearch)]
    [InlineData("write a blog post about our new feature", AgentJobType.ContentGeneration)]
    [InlineData("draft an article on onboarding", AgentJobType.ContentGeneration)]
    [InlineData("summarize this quarter's results", AgentJobType.ContentGeneration)]
    [InlineData("build me a website for my bakery", AgentJobType.Custom)]
    [InlineData("what's the weather like", AgentJobType.Custom)]
    public void Detect_MatchesExpectedType(string prompt, AgentJobType expected)
        => Assert.Equal(expected, AgentJob.Detect(prompt));
}
