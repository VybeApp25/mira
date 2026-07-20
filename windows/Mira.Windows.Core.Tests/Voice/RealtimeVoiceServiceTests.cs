using System.Linq;
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

    [Fact]
    public void BuildToolDefinitions_DeclaresSearchWebWithARequiredQueryParameter()
    {
        var tools = RealtimeVoiceService.BuildToolDefinitions();
        var tool = tools.Values<Newtonsoft.Json.Linq.JObject>().Single(t => (string?)t!["name"] == "search_web")!;

        Assert.Equal("function", (string?)tool["type"]);
        Assert.Equal("object", (string?)tool["parameters"]?["type"]);
        Assert.NotNull(tool["parameters"]?["properties"]?["query"]);
        Assert.Contains("query", tool["parameters"]?["required"]?.Values<string>() ?? Array.Empty<string>());
    }

    [Fact]
    public void BuildToolDefinitions_DeclaresExactlyFiveTools()
    {
        var tools = RealtimeVoiceService.BuildToolDefinitions();
        var names = tools.Values<Newtonsoft.Json.Linq.JObject>().Select(t => (string?)t!["name"]).ToList();

        Assert.Equal(5, tools.Count);
        Assert.Contains("search_web", names);
        Assert.Contains("now_playing", names);
        Assert.Contains("control_spotify", names);
        Assert.Contains("play_video", names);
        Assert.Contains("control_computer", names);
    }

    [Fact]
    public void BuildToolDefinitions_PlayVideoRequiresQuery()
    {
        var tools = RealtimeVoiceService.BuildToolDefinitions();
        var tool = tools.Values<Newtonsoft.Json.Linq.JObject>().Single(t => (string?)t!["name"] == "play_video")!;

        Assert.Equal("function", (string?)tool["type"]);
        Assert.NotNull(tool["parameters"]?["properties"]?["query"]);
        Assert.Contains("query", tool["parameters"]?["required"]?.Values<string>() ?? Array.Empty<string>());
    }

    [Fact]
    public void BuildToolDefinitions_ControlComputerRequiresTask()
    {
        var tools = RealtimeVoiceService.BuildToolDefinitions();
        var tool = tools.Values<Newtonsoft.Json.Linq.JObject>().Single(t => (string?)t!["name"] == "control_computer")!;

        Assert.Equal("function", (string?)tool["type"]);
        Assert.NotNull(tool["parameters"]?["properties"]?["task"]);
        Assert.Contains("task", tool["parameters"]?["required"]?.Values<string>() ?? Array.Empty<string>());
        // Mac's own description explicitly steers the model away from using this
        // for video/watch requests -- confirm the port kept that guidance.
        Assert.Contains("play_video", (string?)tool["description"] ?? "");
    }

    [Fact]
    public void BuildToolDefinitions_NowPlayingHasNoParameters()
    {
        var tools = RealtimeVoiceService.BuildToolDefinitions();
        var tool = tools.Values<Newtonsoft.Json.Linq.JObject>().Single(t => (string?)t!["name"] == "now_playing")!;

        Assert.Equal("function", (string?)tool["type"]);
        Assert.Empty(tool["parameters"]?["required"] ?? new Newtonsoft.Json.Linq.JArray());
    }

    [Fact]
    public void BuildToolDefinitions_ControlSpotifyOnlyExposesImplementedActions()
    {
        var tools = RealtimeVoiceService.BuildToolDefinitions();
        var tool = tools.Values<Newtonsoft.Json.Linq.JObject>().Single(t => (string?)t!["name"] == "control_spotify")!;

        var enumValues = tool["parameters"]?["properties"]?["action"]?["enum"]?.Values<string>().ToList();
        Assert.Equal(new[] { "play_pause", "next", "previous" }, enumValues);
        // Library actions Windows doesn't implement (favorite, playlists, follow, named-song-play)
        // must never appear as selectable options.
        Assert.DoesNotContain("favorite", enumValues!);
        Assert.DoesNotContain("play_song", enumValues!);
    }

    [Theory]
    [InlineData("you")]
    [InlineData("You.")]
    [InlineData("Thanks for watching!")]
    [InlineData("  thank you  ")]
    [InlineData("...")]
    [InlineData("Um")]
    [InlineData("")]
    [InlineData("   ")]
    public void IsPhantomTranscript_FiltersWhisperHallucinations(string raw)
    {
        Assert.True(RealtimeVoiceService.IsPhantomTranscript(raw));
    }

    [Theory]
    [InlineData("yes")]
    [InlineData("no")]
    [InlineData("stop")]
    [InlineData("search the web for who won the world cup")]
    public void IsPhantomTranscript_DoesNotFilterRealUtterances(string raw)
    {
        Assert.False(RealtimeVoiceService.IsPhantomTranscript(raw));
    }
}
