using Mira.Windows.Core.Chat;
using Xunit;

namespace Mira.Windows.Core.Tests.Chat;

public class RouterHandlerTests
{
    [Theory]
    [InlineData("search the web for the world cup schedule", "the world cup schedule")]
    [InlineData("search online for best pizza nearby", "best pizza nearby")]
    [InlineData("search for weather in Tokyo", "weather in Tokyo")]
    [InlineData("look up the capital of France", "the capital of France")]
    [InlineData("look it up please", "please")]
    [InlineData("google the tallest building", "the tallest building")]
    [InlineData("Search current gas prices", "current gas prices")]
    public void ExtractSearchQuery_StripsLeadingFiller(string prompt, string expected)
    {
        Assert.Equal(expected, RouterHandler.ExtractSearchQuery(prompt));
    }

    [Fact]
    public void ExtractSearchQuery_NoFillerPrefix_ReturnsPromptUnchanged()
    {
        var prompt = "what time is the world cup game tonight and who is playing";
        Assert.Equal(prompt, RouterHandler.ExtractSearchQuery(prompt));
    }

}
