using Mira.Windows.Core.Chat;
using Xunit;

namespace Mira.Windows.Core.Tests.Chat;

public class WakeWordSettingsTests
{
    [Theory]
    [InlineData("hey mira")]
    [InlineData("Hey Mira")]
    [InlineData("hey mirror")]
    [InlineData("hey mirra")]
    [InlineData("okay mira")]
    [InlineData("hi mira")]
    [InlineData("so hey mira can you help")]
    public void MatchesTrigger_RecognizesAllTriggerPhrasesCaseInsensitively(string text)
    {
        Assert.True(WakeWordSettings.MatchesTrigger(text));
    }

    [Theory]
    [InlineData("")]
    [InlineData(null)]
    [InlineData("hello world")]
    [InlineData("hey siri")]
    [InlineData("mira")]
    public void MatchesTrigger_RejectsNonTriggerText(string? text)
    {
        Assert.False(WakeWordSettings.MatchesTrigger(text));
    }
}
