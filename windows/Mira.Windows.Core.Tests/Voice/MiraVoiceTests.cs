using Mira.Windows.Core.Voice;
using Xunit;

namespace Mira.Windows.Core.Tests.Voice;

public class MiraVoiceTests
{
    [Theory]
    [InlineData(MiraVoice.Alloy, "alloy", "Alloy — Neutral")]
    [InlineData(MiraVoice.Ash, "ash", "Ash — Calm")]
    [InlineData(MiraVoice.Ballad, "ballad", "Ballad — Warm")]
    [InlineData(MiraVoice.Cedar, "cedar", "Cedar — Grounded")]
    [InlineData(MiraVoice.Coral, "coral", "Coral — Bright")]
    [InlineData(MiraVoice.Echo, "echo", "Echo — Crisp")]
    [InlineData(MiraVoice.Marin, "marin", "Marin — Clear")]
    [InlineData(MiraVoice.Sage, "sage", "Sage — Measured")]
    [InlineData(MiraVoice.Shimmer, "shimmer", "Shimmer — Soft")]
    [InlineData(MiraVoice.Verse, "verse", "Verse — Expressive")]
    public void IdAndLabel_MatchMacExactly(MiraVoice voice, string expectedId, string expectedLabel)
    {
        Assert.Equal(expectedId, voice.Id());
        Assert.Equal(expectedLabel, voice.Label());
    }

    [Fact]
    public void Saved_DefaultsToAlloy_AndRoundTrips()
    {
        var original = MiraVoiceSettings.Saved;
        try
        {
            MiraVoiceSettings.Saved = MiraVoice.Cedar;
            Assert.Equal(MiraVoice.Cedar, MiraVoiceSettings.Saved);

            MiraVoiceSettings.Saved = MiraVoice.Alloy;
            Assert.Equal(MiraVoice.Alloy, MiraVoiceSettings.Saved);
        }
        finally
        {
            MiraVoiceSettings.Saved = original;
        }
    }
}
