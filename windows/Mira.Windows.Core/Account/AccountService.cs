using System.Net.Http.Headers;
using System.Text;
using Mira.Contracts.CheckDevice;
using Mira.Contracts.RegisterDevice;
using Mira.Windows.Core.Auth;
using Mira.Windows.Core.Config;
using Mira.Windows.Core.Device;
using Mira.Windows.Core.Entitlements;

namespace Mira.Windows.Core.Account;

/// <summary>
/// The Windows equivalent of macOS's <c>AccountService</c>
/// (Mira/Services/AccountService.swift) — orchestrates <see cref="SupabaseService"/>
/// (session), <see cref="DeviceFingerprintService"/> (device lock), and
/// <see cref="EntitlementService"/> (plan) into the single sign-in/sign-up flow a
/// UI actually calls. Deliberately narrower than the Swift original: email/password
/// only — no Sign in with Apple, no browser-OAuth fallback (both exist on macOS
/// only to route around an Apple-specific Developer-ID/App-Store entitlement
/// restriction that has no Windows analog; see
/// docs/windows/SECURITY_AND_PRIVACY.md §4). Adding Microsoft/Google OAuth later
/// is a product decision, not a porting gap.
/// </summary>
public sealed class AccountService
{
    private static readonly HttpClient Http = new();

    public static AccountService Shared { get; } = new();

    public AuthState State { get; private set; }
    public SupabaseSession? CurrentUser => SupabaseService.Shared.Session;
    public bool IsSignedIn => State == AuthState.SignedIn;

    public event Action<AuthState>? StateChanged;

    private AccountService()
    {
        State = SupabaseService.Shared.IsSignedIn ? AuthState.SignedIn : AuthState.SignedOut;
        if (State == AuthState.SignedIn) _ = EntitlementService.Shared.FetchAndApplyPlanAsync();
    }

    public async Task SignInAsync(string email, string password, CancellationToken ct = default)
    {
        SetState(AuthState.Loading);
        try
        {
            var session = await SupabaseService.Shared.SignInAsync(email, password, ct);
            SetState(AuthState.SignedIn);
            await EntitlementService.Shared.FetchAndApplyPlanAsync(ct);
            // Fire-and-forget, mirrors the Swift original's `Task { await registerDevice(...) }` —
            // a slow/failed device-registration call shouldn't block the sign-in UI.
            _ = RegisterDeviceAsync(session, ct);
        }
        catch
        {
            SetState(AuthState.SignedOut);
            throw;
        }
    }

    /// <summary>
    /// Throws <see cref="MiraAuthException"/> if this PC already hosts another
    /// free-tier account. Returns normally (with no session change) if signup
    /// succeeded but email confirmation is pending — mirrors the Swift original.
    /// </summary>
    public async Task SignUpAsync(string email, string password, string displayName, CancellationToken ct = default)
    {
        SetState(AuthState.Loading);
        try
        {
            var deviceHash = DeviceFingerprintService.DeviceHash;
            if (!await CheckDeviceAvailableAsync(deviceHash, ct))
            {
                SetState(AuthState.SignedOut);
                throw MiraAuthException.DeviceAlreadyRegistered();
            }

            var session = await SupabaseService.Shared.SignUpAsync(email, password, displayName, ct);
            if (session is null)
            {
                SetState(AuthState.SignedOut); // pending email confirmation — not an error
                return;
            }

            SetState(AuthState.SignedIn);
            await EntitlementService.Shared.FetchAndApplyPlanAsync(ct);
            _ = RegisterDeviceAsync(session, ct);
        }
        catch
        {
            SetState(AuthState.SignedOut);
            throw;
        }
    }

    public void SignOut()
    {
        SupabaseService.Shared.SignOut();
        SetState(AuthState.SignedOut);
    }

    // ---- Device lock ---------------------------------------------------------

    private static async Task<bool> CheckDeviceAvailableAsync(string deviceHash, CancellationToken ct)
    {
        // Public endpoint, called BEFORE a session exists — authorized with the
        // anon key only, mirroring AccountService.swift's checkDeviceAvailable().
        // Fails open (returns true = "available") on any transport/parse error,
        // exactly like the Swift original — a device-lock check that can't reach
        // the server must not block signup entirely.
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, MiraConfig.SupabaseUrl + "/functions/v1/check-device");
            req.Headers.Add("apikey", MiraConfig.SupabaseAnonKey);
            var body = new CheckDeviceRequest { DeviceHash = deviceHash };
            req.Content = new StringContent(body.ToJson(), Encoding.UTF8, "application/json");
            using var resp = await Http.SendAsync(req, ct);
            if (!resp.IsSuccessStatusCode) return true;
            var text = await resp.Content.ReadAsStringAsync(ct);
            return CheckDeviceResponse.FromJson(text).Available;
        }
        catch
        {
            return true;
        }
    }

    /// <summary>
    /// Fire-and-forget after sign-in/sign-up. If the server returns 409 (another
    /// free account owns this device), signs back out so this PC can't be used —
    /// mirrors AccountService.swift's registerDevice().
    /// </summary>
    private static async Task RegisterDeviceAsync(SupabaseSession session, CancellationToken ct)
    {
        try
        {
            var body = new RegisterDeviceRequest { DeviceHash = DeviceFingerprintService.DeviceHash };
            using var req = new HttpRequestMessage(HttpMethod.Post, MiraConfig.SupabaseUrl + "/functions/v1/register-device");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", session.AccessToken);
            req.Content = new StringContent(body.ToJson(), Encoding.UTF8, "application/json");
            using var resp = await Http.SendAsync(req, ct);
            if (resp.StatusCode == System.Net.HttpStatusCode.Conflict)
            {
                SupabaseService.Shared.SignOut();
            }
        }
        catch
        {
            // Best-effort, mirrors the Swift original's `try?`-guarded fire-and-forget.
        }
    }

    private void SetState(AuthState state)
    {
        State = state;
        StateChanged?.Invoke(state);
    }
}
