using Mira.Windows.Core.LiveLookup;
using Xunit;

namespace Mira.Windows.Core.Tests.LiveLookup;

public class WeatherLookupTests
{
    [Theory]
    [InlineData("weather in Atlanta", "Atlanta")]
    [InlineData("what's the weather in Tokyo today?", "Tokyo")]
    [InlineData("is it going to rain in New York tonight", "New York")]
    [InlineData("temperature in Chicago right now", "Chicago")]
    [InlineData("forecast in Seattle this weekend", "Seattle")]
    public void ExtractCity_FindsCityAfterIn_StripsTrailingTimeWords(string prompt, string expected)
    {
        Assert.Equal(expected, WeatherLookup.ExtractCity(prompt));
    }

    [Fact]
    public void ExtractCity_NoInPreposition_ReturnsNull()
    {
        Assert.Null(WeatherLookup.ExtractCity("what's the weather like today"));
    }

    [Fact]
    public void ExtractCity_StripsPunctuation()
    {
        Assert.Equal("Paris", WeatherLookup.ExtractCity("weather in Paris?"));
    }
}
