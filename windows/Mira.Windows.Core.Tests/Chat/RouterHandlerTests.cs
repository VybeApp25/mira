using Mira.Windows.Core.Chat;
using Xunit;
using MemoryCategory = Mira.Windows.Core.Memory.MemoryCategory;

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

    [Theory]
    [InlineData("show me images of golden retrievers", "golden retrievers")]
    [InlineData("images of the northern lights", "the northern lights")]
    [InlineData("pictures of Tokyo at night", "Tokyo at night")]
    [InlineData("find images of red pandas", "red pandas")]
    public void ImageQuery_StripsLeadingFiller(string prompt, string expected)
    {
        Assert.Equal(expected, RouterHandler.ImageQuery(prompt));
    }

    [Theory]
    [InlineData("bring up the usa game highlights from last night", "usa game highlights from last night")]
    [InlineData("play me the trailer for the new batman movie", "trailer for the new batman movie")]
    [InlineData("can you pull up a video of cats falling over", "cats falling over")]
    [InlineData("show me the clip of the buzzer beater", "buzzer beater")]
    public void VideoQuery_StripsFillerBothPasses(string prompt, string expected)
    {
        Assert.Equal(expected, RouterHandler.VideoQuery(prompt));
    }

    [Fact]
    public void VideoQuery_EntirelyFiller_FallsBackToOriginalPrompt()
    {
        Assert.Equal("play", RouterHandler.VideoQuery("play"));
    }

    [Fact]
    public void ExtractUrl_ExplicitHttpsUrl_IsFound()
    {
        Assert.Equal("https://example.com/page", RouterHandler.ExtractUrl("check out https://example.com/page please"));
    }

    [Theory]
    [InlineData("open github.com", "https://github.com/")]
    [InlineData("go to reddit.com", "https://reddit.com/")]
    [InlineData("visit stackoverflow.com", "https://stackoverflow.com/")]
    public void ExtractUrl_OpenPhrasing_BuildsHttpsUrl(string prompt, string expected)
    {
        Assert.Equal(expected, RouterHandler.ExtractUrl(prompt));
    }

    [Fact]
    public void ExtractUrl_NoUrlOrOpenPhrasing_ReturnsNull()
    {
        Assert.Null(RouterHandler.ExtractUrl("what's the weather like"));
    }

    [Fact]
    public void ExtractUrl_OpenPhrasingWithoutDot_ReturnsNull()
    {
        Assert.Null(RouterHandler.ExtractUrl("open settings"));
    }

    [Theory]
    [InlineData("https://example.com")]
    [InlineData("https://sub.example.co.uk/path")]
    public void IsUrlSafe_NormalHost_IsTrue(string url)
    {
        Assert.True(RouterHandler.IsUrlSafe(url));
    }

    [Theory]
    [InlineData("https://bit.ly/abc123")]
    [InlineData("https://tinyurl.com/xyz")]
    public void IsUrlSafe_KnownShortener_IsFalse(string url)
    {
        Assert.False(RouterHandler.IsUrlSafe(url));
    }

    [Fact]
    public void IsUrlSafe_RawIpAddress_IsFalse()
    {
        Assert.False(RouterHandler.IsUrlSafe("http://192.168.1.1/admin"));
    }

    [Theory]
    [InlineData("skip this song", RouterHandler.SpotifyAction.Next)]
    [InlineData("next track", RouterHandler.SpotifyAction.Next)]
    [InlineData("go back", RouterHandler.SpotifyAction.Previous)]
    [InlineData("previous song", RouterHandler.SpotifyAction.Previous)]
    [InlineData("pause spotify", RouterHandler.SpotifyAction.Toggle)]
    [InlineData("play", RouterHandler.SpotifyAction.Toggle)]
    [InlineData("play it", RouterHandler.SpotifyAction.Toggle)]
    public void DetectSpotifyAction_BasicTransport(string prompt, RouterHandler.SpotifyAction expected)
    {
        Assert.Equal(expected, RouterHandler.DetectSpotifyAction(prompt));
    }

    [Theory]
    [InlineData("favorite this song")]
    [InlineData("add this to my gym playlist")]
    [InlineData("follow this artist")]
    [InlineData("play bohemian rhapsody")]
    public void DetectSpotifyAction_LibraryActions_AreUnsupported(string prompt)
    {
        Assert.Equal(RouterHandler.SpotifyAction.Unsupported, RouterHandler.DetectSpotifyAction(prompt));
    }

    [Theory]
    [InlineData("send this email to my boss")]
    [InlineData("delete all my downloads")]
    [InlineData("buy this on Amazon")]
    [InlineData("submit the form")]
    [InlineData("cancel my subscription")]
    [InlineData("checkout with my saved card")]
    public void IsRiskyPrompt_KnownRiskyPhrasing_IsTrue(string prompt)
    {
        Assert.True(RouterHandler.IsRiskyPrompt(prompt));
    }

    [Theory]
    [InlineData("open notepad")]
    [InlineData("what's on my screen")]
    [InlineData("scroll down a bit")]
    public void IsRiskyPrompt_OrdinaryPhrasing_IsFalse(string prompt)
    {
        Assert.False(RouterHandler.IsRiskyPrompt(prompt));
    }

    [Theory]
    [InlineData("do you remember my favorite color", "my favorite color")]
    [InlineData("what do you know about my job", "my job")]
    [InlineData("recall what editor I use", "what editor I use")]
    [InlineData("what did i tell you about my dog", "my dog")]
    public void ExtractMemoryQuery_FindsQueryAfterPrefix(string prompt, string expected)
    {
        Assert.Equal(expected, RouterHandler.ExtractMemoryQuery(prompt));
    }

    [Fact]
    public void ExtractMemoryQuery_NoPrefix_ReturnsPromptUnchanged()
    {
        var prompt = "tell me about myself";
        Assert.Equal(prompt, RouterHandler.ExtractMemoryQuery(prompt));
    }

    [Fact]
    public void ParseMemoryFact_WellFormedJson_ParsesAllFields()
    {
        const string reply = """{"key": "favorite_editor", "value": "VS Code", "category": "preference"}""";
        var (key, value, category) = RouterHandler.ParseMemoryFact(reply);
        Assert.Equal("favorite_editor", key);
        Assert.Equal("VS Code", value);
        Assert.Equal(MemoryCategory.Preference, category);
    }

    [Fact]
    public void ParseMemoryFact_ProseWrappedJson_StillExtracts()
    {
        const string reply = "Sure! Here's the fact:\n```json\n{\"key\": \"name\", \"value\": \"Alex\", \"category\": \"person\"}\n```";
        var (key, value, category) = RouterHandler.ParseMemoryFact(reply);
        Assert.Equal("name", key);
        Assert.Equal("Alex", value);
        Assert.Equal(MemoryCategory.Person, category);
    }

    [Fact]
    public void ParseMemoryFact_MissingCategory_FallsBackToFact()
    {
        const string reply = """{"key": "k", "value": "v"}""";
        var (_, _, category) = RouterHandler.ParseMemoryFact(reply);
        Assert.Equal(MemoryCategory.Fact, category);
    }

    [Fact]
    public void ParseMemoryFact_UnrecognizedCategory_FallsBackToFact()
    {
        const string reply = """{"key": "k", "value": "v", "category": "nonsense"}""";
        var (_, _, category) = RouterHandler.ParseMemoryFact(reply);
        Assert.Equal(MemoryCategory.Fact, category);
    }

    [Fact]
    public void ParseMemoryFact_NoJsonObject_ReturnsNullKeyAndValue()
    {
        var (key, value, _) = RouterHandler.ParseMemoryFact("I'm not sure what to remember here.");
        Assert.Null(key);
        Assert.Null(value);
    }

    [Fact]
    public void ParseMemoryFact_MissingValue_ReturnsNullKeyAndValue()
    {
        const string reply = """{"key": "k"}""";
        var (key, value, _) = RouterHandler.ParseMemoryFact(reply);
        Assert.Null(key);
        Assert.Null(value);
    }
}
