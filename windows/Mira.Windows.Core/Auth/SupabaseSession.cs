using Newtonsoft.Json;

namespace Mira.Windows.Core.Auth;

/// <summary>
/// The Windows equivalent of macOS's <c>SupabaseSession</c> struct
/// (Mira/Services/SupabaseService.swift). Same five fields, same source (derived
/// from a Supabase GoTrue <c>SupabaseAuthResponse</c> — see
/// shared/contracts/auth/session-response.schema.json). Persisted via
/// <see cref="SecureSessionStore"/> (DPAPI-encrypted file), not plaintext —
/// a deliberate improvement over the macOS client's UserDefaults storage, per
/// docs/windows/SECURITY_AND_PRIVACY.md §4.
/// </summary>
public sealed class SupabaseSession
{
    [JsonProperty("access_token")]
    public required string AccessToken { get; init; }

    [JsonProperty("refresh_token")]
    public required string RefreshToken { get; init; }

    [JsonProperty("user_id")]
    public required string UserId { get; init; }

    [JsonProperty("email")]
    public string? Email { get; init; }

    [JsonProperty("display_name")]
    public string? DisplayName { get; init; }

    /// <summary>UTC instant the access token expires — mirrors Swift's <c>expiresAt: Date</c>.</summary>
    [JsonProperty("expires_at")]
    public required DateTimeOffset ExpiresAt { get; init; }
}
