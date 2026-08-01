using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;
using Mira.Windows.Core.Storage;

namespace Mira.Windows.Core.Device;

/// <summary>
/// The Windows equivalent of macOS's <c>DeviceFingerprintService</c>
/// (Mira/Services/DeviceFingerprintService.swift) — same construction
/// (SHA-256 of a stable hardware identifier + a DPAPI/Keychain-persisted random
/// ID, same "mira-v1:" prefix so the hash shape matches), different primitives:
/// <list type="bullet">
/// <item>IOKit <c>IOPlatformSerialNumber</c> → the <c>MachineGuid</c> registry value
/// under <c>HKLM\SOFTWARE\Microsoft\Cryptography</c>. This is a deliberate
/// deviation from docs/windows/WINDOWS_ARCHITECTURE.md §6's suggestion of WMI's
/// <c>Win32_ComputerSystemProduct.UUID</c> — <c>MachineGuid</c> is the more
/// commonly used .NET device-fingerprint primitive, is simpler (no
/// <c>System.Management</c>/WMI dependency), and is equally stable across
/// reboots (set once per Windows installation, persists until reinstall).</item>
/// <item>Keychain (<c>SecItemAdd</c>/<c>SecItemCopyMatching</c>) → <see cref="DpapiFileStore"/>.</item>
/// </list>
/// The server treats this hash as an opaque string either way (see
/// shared/contracts/edge-functions/check-device.schema.json /
/// register-device.schema.json) — no backend change is needed for this to work.
/// </summary>
public static class DeviceFingerprintService
{
    private const string PersistentIdFileName = "device_id.dat";

    public static string DeviceHash
    {
        get
        {
            var machineId = MachineGuid() ?? "no-machine-id";
            var persistentId = PersistentDeviceId();
            var combined = $"mira-v1:{machineId}:{persistentId}";
            var hash = SHA256.HashData(Encoding.UTF8.GetBytes(combined));
            return Convert.ToHexStringLower(hash);
        }
    }

    private static string? MachineGuid()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography");
            return key?.GetValue("MachineGuid") as string;
        }
        catch (System.Security.SecurityException)
        {
            return null; // fall back to the "no-machine-id" placeholder above
        }
    }

    private static string PersistentDeviceId()
    {
        var existing = DpapiFileStore.Read(PersistentIdFileName);
        if (existing is not null) return Encoding.UTF8.GetString(existing);

        var newId = Guid.NewGuid().ToString();
        DpapiFileStore.Write(PersistentIdFileName, Encoding.UTF8.GetBytes(newId));
        return newId;
    }
}
