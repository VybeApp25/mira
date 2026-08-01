using Mira.Windows.Core.Auth;
using Newtonsoft.Json;
using Xunit;

namespace Mira.Windows.Core.Tests.Auth;

/// <summary>
/// Pure JSON round-trip test — no file I/O, no DPAPI, no network. Confirms
/// <see cref="SupabaseSession"/>'s <c>JsonProperty</c> field names match what
/// <see cref="Mira.Windows.Core.Auth.SecureSessionStore"/> actually persists,
/// independent of the storage mechanism itself (covered separately by
/// DpapiFileStoreTests).
/// </summary>
public class SupabaseSessionSerializationTests
{
    [Fact]
    public void RoundTrips_AllFields()
    {
        var original = new SupabaseSession
        {
            AccessToken = "test-access-token",
            RefreshToken = "test-refresh-token",
            UserId = "11111111-1111-1111-1111-111111111111",
            Email = "test@example.com",
            DisplayName = "Test User",
            ExpiresAt = new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero),
        };

        var json = JsonConvert.SerializeObject(original);
        var restored = JsonConvert.DeserializeObject<SupabaseSession>(json);

        Assert.NotNull(restored);
        Assert.Equal(original.AccessToken, restored!.AccessToken);
        Assert.Equal(original.RefreshToken, restored.RefreshToken);
        Assert.Equal(original.UserId, restored.UserId);
        Assert.Equal(original.Email, restored.Email);
        Assert.Equal(original.DisplayName, restored.DisplayName);
        Assert.Equal(original.ExpiresAt, restored.ExpiresAt);
    }

    [Fact]
    public void UsesSnakeCaseFieldNames_MatchingSupabaseConvention()
    {
        var session = new SupabaseSession
        {
            AccessToken = "a",
            RefreshToken = "b",
            UserId = "c",
            ExpiresAt = DateTimeOffset.UtcNow,
        };

        var json = JsonConvert.SerializeObject(session);

        Assert.Contains("\"access_token\"", json);
        Assert.Contains("\"refresh_token\"", json);
        Assert.Contains("\"user_id\"", json);
        Assert.Contains("\"expires_at\"", json);
    }
}
