using System.Text.RegularExpressions;
using Mira.Windows.Core.Device;
using Xunit;

namespace Mira.Windows.Core.Tests.Device;

/// <summary>
/// These are lightweight integration tests, not pure unit tests: <see cref="DeviceFingerprintService"/>
/// reads the real Windows registry and writes/reads the real DPAPI-protected
/// persistent-ID file under %LOCALAPPDATA%\Mira\device_id.dat on whatever machine
/// runs them. That's intentional and safe here — the persisted ID is idempotent
/// (created once, then reused forever, exactly like the real app would do on
/// first run), so running these tests can't corrupt anything; it just confirms
/// the DPAPI round-trip actually works on this machine, not merely that the code
/// compiles.
/// </summary>
public class DeviceFingerprintServiceTests
{
    [Fact]
    public void DeviceHash_IsA64CharacterLowercaseHexString()
    {
        var hash = DeviceFingerprintService.DeviceHash;
        Assert.Matches(new Regex("^[0-9a-f]{64}$"), hash);
    }

    [Fact]
    public void DeviceHash_IsStableAcrossCalls()
    {
        var first = DeviceFingerprintService.DeviceHash;
        var second = DeviceFingerprintService.DeviceHash;
        Assert.Equal(first, second);
    }
}
