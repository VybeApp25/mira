using Mira.Windows.Core.Voice;
using Xunit;

namespace Mira.Windows.Core.Tests.Voice;

public class RealtimeVoiceServiceTests
{
    [Fact]
    public void BuildTurnDetectionConfig_MatchesMacExactly()
    {
        var config = RealtimeVoiceService.BuildTurnDetectionConfig();

        Assert.Equal("server_vad", (string?)config["type"]);
        Assert.Equal(0.65m, (decimal?)config["threshold"]);
        Assert.Equal(300, (int?)config["prefix_padding_ms"]);
        Assert.Equal(400, (int?)config["silence_duration_ms"]);
    }

    [Fact]
    public void BuildTurnDetectionConfig_ThresholdSerializesWithoutFloatingPointNoise()
    {
        // The Realtime API rejects thresholds with excess decimal places (the exact
        // bug the Swift original works around with NSDecimalNumber) -- confirm the
        // C# decimal literal serializes as exactly "0.65", not "0.65000000000000002".
        var config = RealtimeVoiceService.BuildTurnDetectionConfig();
        var json = config.ToString(Newtonsoft.Json.Formatting.None);
        Assert.Contains("\"threshold\":0.65", json);
    }
}
