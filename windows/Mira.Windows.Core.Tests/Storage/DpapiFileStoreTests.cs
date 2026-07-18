using System.Text;
using Mira.Windows.Core.Storage;
using Xunit;

namespace Mira.Windows.Core.Tests.Storage;

/// <summary>
/// Uses its own dedicated file name (never "session.dat"/"device_id.dat"/
/// "entitlement.json") specifically so these tests can never collide with or
/// corrupt real app state on the machine running them — each test cleans up
/// after itself in a <c>finally</c> block.
/// </summary>
public class DpapiFileStoreTests
{
    private const string TestFileName = "_dpapi_file_store_tests.tmp";

    public DpapiFileStoreTests() => DpapiFileStore.Delete(TestFileName); // in case a prior run crashed mid-test

    [Fact]
    public void WriteThenRead_RoundTripsExactBytes()
    {
        var payload = Encoding.UTF8.GetBytes("mira windows dpapi round-trip — not a real secret");
        try
        {
            DpapiFileStore.Write(TestFileName, payload);
            var result = DpapiFileStore.Read(TestFileName);
            Assert.Equal(payload, result);
        }
        finally
        {
            DpapiFileStore.Delete(TestFileName);
        }
    }

    [Fact]
    public void Read_ReturnsNull_WhenFileDoesNotExist()
    {
        DpapiFileStore.Delete(TestFileName); // ensure absent
        Assert.Null(DpapiFileStore.Read(TestFileName));
    }

    [Fact]
    public void StoredFile_IsNotPlaintext()
    {
        var secretMarker = "this-must-not-appear-in-plaintext-on-disk";
        try
        {
            DpapiFileStore.Write(TestFileName, Encoding.UTF8.GetBytes(secretMarker));
            var rawBytesOnDisk = File.ReadAllBytes(LocalAppData.PathFor(TestFileName));
            var rawTextOnDisk = Encoding.UTF8.GetString(rawBytesOnDisk);
            Assert.DoesNotContain(secretMarker, rawTextOnDisk);
        }
        finally
        {
            DpapiFileStore.Delete(TestFileName);
        }
    }
}
