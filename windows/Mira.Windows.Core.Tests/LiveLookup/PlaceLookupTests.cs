using Mira.Windows.Core.LiveLookup;
using Xunit;

namespace Mira.Windows.Core.Tests.LiveLookup;

public class PlaceLookupTests
{
    [Theory]
    [InlineData("where is the Eiffel Tower", "the Eiffel Tower")]
    [InlineData("find a coffee shop nearby", "a coffee shop nearby")]
    [InlineData("directions to the airport", "the airport")]
    [InlineData("navigate to Central Park", "Central Park")]
    [InlineData("map of downtown Chicago", "downtown Chicago")]
    public void ExtractPlaceQuery_StripsLeadingFiller(string prompt, string expected)
    {
        Assert.Equal(expected, PlaceLookup.ExtractPlaceQuery(prompt));
    }

    [Fact]
    public void ExtractPlaceQuery_NoFillerPrefix_ReturnsPromptUnchanged()
    {
        Assert.Equal("Times Square", PlaceLookup.ExtractPlaceQuery("Times Square"));
    }
}
