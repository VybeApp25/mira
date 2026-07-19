using Mira.Windows.Core.Browser;
using Xunit;

namespace Mira.Windows.Core.Tests.Browser;

public class InstalledBrowsersTests
{
    [Fact]
    public void ExtractExePath_QuotedPathWithArgs_ExtractsPathOnly()
    {
        var result = InstalledBrowsers.ExtractExePath("\"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe\" -- \"%1\"");
        Assert.Equal(@"C:\Program Files\Google\Chrome\Application\chrome.exe", result);
    }

    [Fact]
    public void ExtractExePath_QuotedPathNoArgs_ExtractsPath()
    {
        var result = InstalledBrowsers.ExtractExePath("\"C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe\"");
        Assert.Equal(@"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe", result);
    }

    [Fact]
    public void ExtractExePath_UnquotedPathWithArgs_ExtractsFirstToken()
    {
        var result = InstalledBrowsers.ExtractExePath(@"C:\Browsers\browser.exe %1");
        Assert.Equal(@"C:\Browsers\browser.exe", result);
    }

    [Fact]
    public void ExtractExePath_UnquotedPathNoArgs_ReturnsWholeString()
    {
        var result = InstalledBrowsers.ExtractExePath(@"C:\Browsers\browser.exe");
        Assert.Equal(@"C:\Browsers\browser.exe", result);
    }

    [Fact]
    public void ExtractExePath_UnclosedQuote_ReturnsNull()
    {
        var result = InstalledBrowsers.ExtractExePath("\"C:\\Browsers\\broken.exe");
        Assert.Null(result);
    }

    [Fact]
    public void ExtractExePath_Empty_ReturnsNull()
    {
        Assert.Null(InstalledBrowsers.ExtractExePath("   "));
    }
}
