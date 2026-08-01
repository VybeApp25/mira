using Mira.Windows.Core.Storage;
using Newtonsoft.Json;

namespace Mira.Windows.Core.Auth;

/// <summary>
/// Persists/restores the current <see cref="SupabaseSession"/> via
/// <see cref="DpapiFileStore"/>. The macOS client stores the equivalent
/// (<c>SupabaseSession</c>, JSON-encoded) in plaintext in <c>UserDefaults</c>
/// (<c>SupabaseService.swift</c>'s <c>save(_:)</c>/<c>loadSession()</c>) — this is
/// a deliberate improvement, not a straight port: a session's access/refresh
/// tokens are bearer credentials, and DPAPI-at-rest protection costs nothing here
/// since .NET ships it. See docs/windows/SECURITY_AND_PRIVACY.md §4.
/// </summary>
public static class SecureSessionStore
{
    private const string FileName = "session.dat";

    public static void Save(SupabaseSession session)
    {
        var json = JsonConvert.SerializeObject(session);
        DpapiFileStore.Write(FileName, System.Text.Encoding.UTF8.GetBytes(json));
    }

    public static SupabaseSession? Load()
    {
        var bytes = DpapiFileStore.Read(FileName);
        if (bytes is null) return null;
        try
        {
            return JsonConvert.DeserializeObject<SupabaseSession>(System.Text.Encoding.UTF8.GetString(bytes));
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static void Clear() => DpapiFileStore.Delete(FileName);
}
