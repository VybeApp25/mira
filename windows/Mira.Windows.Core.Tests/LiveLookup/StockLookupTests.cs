using Mira.Windows.Core.LiveLookup;
using Xunit;

namespace Mira.Windows.Core.Tests.LiveLookup;

public class StockLookupTests
{
    [Theory]
    [InlineData("what's $AAPL trading at", "AAPL")]
    [InlineData("TSLA stock price", "TSLA")]
    [InlineData("price of MSFT", "MSFT")]
    [InlineData("stock of NVDA", "NVDA")]
    [InlineData("quote for GOOG", "GOOG")]
    public void ExtractTicker_FindsSymbol(string prompt, string expected)
    {
        Assert.Equal(expected, StockLookup.ExtractTicker(prompt));
    }

    [Fact]
    public void ExtractTicker_NoMatch_ReturnsEmpty()
    {
        Assert.Equal("", StockLookup.ExtractTicker("how's the weather today"));
    }
}
