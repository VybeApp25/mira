using Mira.Windows.Core.Routing;
using Xunit;

namespace Mira.Windows.Core.Tests.Routing;

/// <summary>
/// Pins the deterministic classifier (<see cref="RouterService.Route"/>) against
/// inputs chosen to match the exact phrase lists in the confirmed macOS source
/// (Mira/Services/RouterService.swift) — a pure function, no network, no auth,
/// safe to test exhaustively.
/// </summary>
public class RouterServiceTests
{
    private static readonly RouterService Router = new();
    private static readonly RouterContext EmptyContext = new();

    [Theory]
    [InlineData("hi")]
    [InlineData("hello")]
    [InlineData("thanks")]
    [InlineData("what can you do")]
    public void SimpleGreetings_RouteToLocalResponse(string prompt)
        => Assert.Equal(MiraRoute.LocalResponse, Router.Route(prompt, EmptyContext).Route);

    [Theory]
    [InlineData("play some spotify")]
    [InlineData("pause spotify")]
    [InlineData("skip this on spotify")]
    public void SpotifyMentions_RouteToSpotifyControl(string prompt)
        => Assert.Equal(MiraRoute.SpotifyControl, Router.Route(prompt, EmptyContext).Route);

    [Theory]
    [InlineData("what song is this")]
    [InlineData("who sings this")]
    [InlineData("what's playing")]
    public void TrackIdentifyQuestions_RouteToMusicQuery_NotSpotifyControl(string prompt)
        => Assert.Equal(MiraRoute.MusicQuery, Router.Route(prompt, EmptyContext).Route);

    [Fact]
    public void ExplicitHttpsUrl_RoutesToOpenUrl()
    {
        var decision = Router.Route("open https://example.com please", EmptyContext);
        Assert.Equal(MiraRoute.OpenUrl, decision.Route);
    }

    [Fact]
    public void ShortenedUrl_RoutesToConfirmationRequired()
    {
        var decision = Router.Route("open https://bit.ly/abc123", EmptyContext);
        Assert.Equal(MiraRoute.ConfirmationRequired, decision.Route);
    }

    [Theory]
    [InlineData("show me the highlights on youtube")]
    [InlineData("pull up a youtube video of the game")]
    public void VideoWatchRequests_RouteToVideoPlayback_NotComputerUse(string prompt)
        => Assert.Equal(MiraRoute.VideoPlayback, Router.Route(prompt, EmptyContext).Route);

    [Theory]
    [InlineData("click on the submit button")]
    [InlineData("open the browser")]
    public void ExplicitDesktopControlRequests_RouteToComputerUse(string prompt)
        => Assert.Equal(MiraRoute.ComputerUse, Router.Route(prompt, EmptyContext).Route);

    [Fact]
    public void AnyYouTubeMention_RoutesToVideoPlayback_EvenWithComputerUsePhrasing()
        // matchesVideoRequest is checked before matchesComputerUse in both the Swift
        // original and this port — any "youtube" mention wins, by design (the Swift
        // comment: video watch intent "must beat computerUse... below").
        => Assert.Equal(MiraRoute.VideoPlayback, Router.Route("open the browser and go on youtube", EmptyContext).Route);

    [Theory]
    [InlineData("what's the weather like today")]
    [InlineData("is it going to rain")]
    [InlineData("do i need a jacket")]
    public void WeatherQuestions_RouteToWeatherLookup(string prompt)
        => Assert.Equal(MiraRoute.WeatherLookup, Router.Route(prompt, EmptyContext).Route);

    [Theory]
    [InlineData("ask gpt about this")]
    [InlineData("use chatgpt to explain")]
    public void GptRequests_RouteToGptQuery(string prompt)
        => Assert.Equal(MiraRoute.GptQuery, Router.Route(prompt, EmptyContext).Route);

    [Fact]
    public void MemoryWritePhrase_RoutesToMemoryWrite()
        => Assert.Equal(MiraRoute.MemoryWrite, Router.Route("remember that I like dark mode", EmptyContext).Route);

    [Fact]
    public void MemoryQueryPhrase_RoutesToMemoryQuery()
        => Assert.Equal(MiraRoute.MemoryQuery, Router.Route("do you remember my name", EmptyContext).Route);

    [Fact]
    public void DangerousCommand_RoutesToConfirmationRequiredAndIsFlaggedDangerous()
    {
        var decision = Router.Route("please rm -rf / everything", EmptyContext);
        Assert.Equal(MiraRoute.ConfirmationRequired, decision.Route);
        Assert.True(decision.IsDangerous);
    }

    [Fact]
    public void VagueOneWordPrompt_WithNoHistory_RoutesToClarificationRequired()
    {
        var decision = Router.Route("do it", EmptyContext);
        Assert.Equal(MiraRoute.ClarificationRequired, decision.Route);
    }

    [Fact]
    public void UnmatchedComplexPrompt_FallsBackToHigherModel()
    {
        var decision = Router.Route("Explain the tradeoffs between REST and GraphQL for a mobile app backend.", EmptyContext);
        Assert.Equal(MiraRoute.HigherModel, decision.Route);
        Assert.Equal(0.60, decision.Confidence);
    }

    [Theory]
    [InlineData("draft an email to my landlord")]
    [InlineData("check my inbox")]
    public void EmailPhrases_RouteToEmailTask(string prompt)
        => Assert.Equal(MiraRoute.EmailTask, Router.Route(prompt, EmptyContext).Route);

    [Theory]
    [InlineData("create a pull request")]
    [InlineData("git commit this")]
    public void RepoPhrases_RouteToRepoTask(string prompt)
        => Assert.Equal(MiraRoute.RepoTask, Router.Route(prompt, EmptyContext).Route);

    [Fact]
    public void ExtractUrl_FindsExplicitScheme()
        => Assert.Equal("https://example.com/", RouterService.ExtractUrl("check out https://example.com for details"));

    [Fact]
    public void ExtractUrl_FindsOpenPrefixedDomain()
        => Assert.Equal("https://example.com/", RouterService.ExtractUrl("open example.com"));

    [Fact]
    public void ExtractUrl_ReturnsNull_WhenNoUrlPresent()
        => Assert.Null(RouterService.ExtractUrl("what's the weather like"));
}
