using System.Security.Cryptography;

namespace Mira.Windows.Core.Storage;

/// <summary>
/// Encrypts a byte payload with Windows DPAPI (<see cref="ProtectedData"/>,
/// <see cref="DataProtectionScope.CurrentUser"/>) and writes it to a file under
/// <see cref="LocalAppData"/>. This is the Windows equivalent of the two Keychain
/// call sites on macOS (<c>DeviceFingerprintService.swift</c>'s persisted device
/// UUID, <c>SpotifyAuthService.swift</c>'s OAuth refresh token — see
/// docs/windows/SECURITY_AND_PRIVACY.md §4) — same intent (protect a secret at
/// rest, scoped to the signed-in Windows user, never roams to another machine),
/// different underlying primitive (DPAPI vs. Keychain Services).
/// </summary>
public static class DpapiFileStore
{
    public static void Write(string fileName, byte[] plaintext)
    {
        var encrypted = ProtectedData.Protect(plaintext, optionalEntropy: null, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(LocalAppData.PathFor(fileName), encrypted);
    }

    /// <returns>The decrypted bytes, or <c>null</c> if the file doesn't exist.</returns>
    public static byte[]? Read(string fileName)
    {
        var path = LocalAppData.PathFor(fileName);
        if (!File.Exists(path)) return null;
        var encrypted = File.ReadAllBytes(path);
        try
        {
            return ProtectedData.Unprotect(encrypted, optionalEntropy: null, DataProtectionScope.CurrentUser);
        }
        catch (CryptographicException)
        {
            // Encrypted by a different user profile, or corrupted — treat as absent
            // rather than crashing (mirrors the Swift stores' `try?`-and-fall-through
            // pattern on decode failure, e.g. SupabaseService.loadSession()).
            return null;
        }
    }

    public static void Delete(string fileName)
    {
        var path = LocalAppData.PathFor(fileName);
        if (File.Exists(path)) File.Delete(path);
    }
}
