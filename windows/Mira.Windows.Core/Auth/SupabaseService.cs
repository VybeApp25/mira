using System.Net.Http.Headers;
using System.Text;
using Mira.Windows.Core.Config;
using Newtonsoft.Json.Linq;
using Mira.Contracts.SignInRequest;
using Mira.Contracts.SignUpRequest;

namespace Mira.Windows.Core.Auth;

/// <summary>
/// The Windows equivalent of macOS's <c>SupabaseService</c>
/// (Mira/Services/SupabaseService.swift) — same responsibilities: email/password
/// sign-in and sign-up against Supabase GoTrue, session persistence, and
/// proactive + reactive JWT refresh. Deliberately narrower than the Swift original
/// for this first milestone: no native Sign in with Apple and no browser-OAuth
/// fallback (both exist on macOS only to work around Apple's own
/// Developer-ID-vs-App-Store entitlement restriction — a constraint that simply
/// doesn't exist on Windows; see docs/windows/SECURITY_AND_PRIVACY.md §4). Adding
/// a Microsoft/Google OAuth sign-in option later is a product decision, not a
/// porting gap, and is left for a later phase.
/// </summary>
public sealed class SupabaseService
{
    private static readonly HttpClient Http = new();

    public static SupabaseService Shared { get; } = new();

    /// <summary>
    /// Thread-safe mirror of the current JWT, exactly like Swift's
    /// <c>nonisolated(unsafe) static var cachedAccessToken</c> — lets call sites that
    /// aren't routed through this service's own methods (future provider-proxy
    /// clients) attach the current token without taking a lock.
    /// </summary>
    public static volatile string CachedAccessToken = "";

    private readonly string _baseUrl = MiraConfig.SupabaseUrl;
    private readonly string _anonKey = MiraConfig.SupabaseAnonKey;

    private SupabaseSession? _session;
    private Task? _refreshInFlight;
    private readonly object _refreshGate = new();

    private SupabaseService()
    {
        _session = SecureSessionStore.Load();
        CachedAccessToken = _session?.AccessToken ?? "";
    }

    public SupabaseSession? Session => _session;
    public bool IsSignedIn => _session is not null;

    /// <summary>Fires whenever the session changes (sign-in, sign-out, refresh).</summary>
    public event Action<SupabaseSession?>? SessionChanged;

    // ---- Sign in ------------------------------------------------------------

    public async Task<SupabaseSession> SignInAsync(string email, string password, CancellationToken ct = default)
    {
        var body = new Mira.Contracts.SignInRequest.SupabaseSignInRequest { Email = email, Password = password };
        var auth = await PostForAuthAsync("/auth/v1/token?grant_type=password", body.ToJson(), ct);
        var session = MakeSession(auth!);
        SetSession(session);
        return session;
    }

    /// <summary>
    /// Returns <c>null</c> when signup succeeded but email confirmation is
    /// required (not an error — mirrors SupabaseService.swift's signUp exactly).
    /// </summary>
    public async Task<SupabaseSession?> SignUpAsync(string email, string password, string displayName, CancellationToken ct = default)
    {
        var body = new Mira.Contracts.SignUpRequest.SupabaseSignUpRequest
        {
            Email = email,
            Password = password,
            Data = new Mira.Contracts.SignUpRequest.Data { DisplayName = displayName },
        };
        var auth = await PostForAuthAsync("/auth/v1/signup", body.ToJson(), ct, allowMissingToken: true);
        if (auth is null || string.IsNullOrEmpty(auth.AccessToken)) return null;
        var session = MakeSession(auth);
        SetSession(session);
        return session;
    }

    // ---- Refresh -------------------------------------------------------------

    public async Task RefreshAsync(CancellationToken ct = default)
    {
        if (_session is null) throw new InvalidOperationException("No session to refresh.");
        var body = new JObject { ["refresh_token"] = _session.RefreshToken }.ToString(Newtonsoft.Json.Formatting.None);
        var auth = await PostForAuthAsync("/auth/v1/token?grant_type=refresh_token", body, ct);
        SetSession(MakeSession(auth!));
    }

    /// <summary>
    /// Refreshes if the token is expired or within <paramref name="buffer"/> of
    /// expiring; no-op otherwise. Mirrors <c>ensureFreshToken(buffer:)</c> —
    /// including signing out on an unrecoverable 400/401 rather than retrying forever.
    /// </summary>
    public async Task EnsureFreshTokenAsync(TimeSpan? buffer = null, CancellationToken ct = default)
    {
        buffer ??= TimeSpan.FromSeconds(120);
        if (_session is null) return;
        if (_session.ExpiresAt - DateTimeOffset.UtcNow > buffer) return;
        try { await SingleFlightRefreshAsync(ct); }
        catch (SupabaseAuthException ex) when (ex.StatusCode is 400 or 401) { SignOut(); }
    }

    /// <summary>
    /// Forces a refresh in response to a server 401 (the token was rejected even
    /// though our clock still considered it valid). Returns whether a usable
    /// session remains. Mirrors <c>refreshAfter401()</c>.
    /// </summary>
    public async Task<bool> RefreshAfter401Async(CancellationToken ct = default)
    {
        if (_session is null) return false;
        try { await SingleFlightRefreshAsync(ct); return _session is not null; }
        catch (SupabaseAuthException ex) when (ex.StatusCode is 400 or 401) { SignOut(); return false; }
    }

    /// <summary>
    /// Concurrent callers share one in-flight refresh — rotating the single-use
    /// refresh token twice would invalidate one caller. Mirrors
    /// <c>singleFlightRefresh()</c>'s <c>Task</c>-reuse pattern.
    /// </summary>
    private Task SingleFlightRefreshAsync(CancellationToken ct)
    {
        lock (_refreshGate)
        {
            _refreshInFlight ??= RefreshAsync(ct).ContinueWith(t =>
            {
                lock (_refreshGate) { _refreshInFlight = null; }
                if (t.IsFaulted) throw t.Exception!.GetBaseException();
            }, TaskContinuationOptions.ExecuteSynchronously);
            return _refreshInFlight;
        }
    }

    // ---- Sign out --------------------------------------------------------

    public void SignOut() => SetSession(null);

    // ---- Authenticated request helper -------------------------------------

    /// <summary>
    /// Sends an authenticated request to a Supabase REST/RPC path (e.g.
    /// <c>/rest/v1/profiles?select=plan</c>). Mirrors <c>authedRequest(path:method:body:)</c>.
    /// </summary>
    public async Task<string> AuthedRequestAsync(string path, HttpMethod method, string? bodyJson = null, CancellationToken ct = default)
    {
        if (_session is null) throw new SupabaseAuthException("Not signed in.");
        using var req = new HttpRequestMessage(method, _baseUrl + path);
        req.Headers.Add("apikey", _anonKey);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _session.AccessToken);
        if (bodyJson is not null) req.Content = new StringContent(bodyJson, Encoding.UTF8, "application/json");

        using var resp = await Http.SendAsync(req, ct);
        var text = await resp.Content.ReadAsStringAsync(ct);
        if (!resp.IsSuccessStatusCode) throw SupabaseAuthException.FromErrorBody((int)resp.StatusCode, text);
        return text;
    }

    // ---- Internals -----------------------------------------------------------

    private async Task<Mira.Contracts.SessionResponse.SupabaseAuthResponse?> PostForAuthAsync(
        string path, string bodyJson, CancellationToken ct, bool allowMissingToken = false)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, _baseUrl + path);
        req.Headers.Add("apikey", _anonKey);
        req.Content = new StringContent(bodyJson, Encoding.UTF8, "application/json");

        HttpResponseMessage resp;
        try { resp = await Http.SendAsync(req, ct); }
        catch (HttpRequestException ex) { throw new SupabaseAuthException(ex.Message, null, ex); }

        var text = await resp.Content.ReadAsStringAsync(ct);
        if (!resp.IsSuccessStatusCode) throw SupabaseAuthException.FromErrorBody((int)resp.StatusCode, text);

        try
        {
            return Mira.Contracts.SessionResponse.SupabaseAuthResponse.FromJson(text);
        }
        catch (Newtonsoft.Json.JsonException)
        {
            if (allowMissingToken) return null; // 200 with no session body — e.g. pending email confirmation
            throw new SupabaseAuthException("Unexpected response from Supabase auth.");
        }
    }

    private static SupabaseSession MakeSession(Mira.Contracts.SessionResponse.SupabaseAuthResponse auth) => new()
    {
        AccessToken = auth.AccessToken,
        RefreshToken = auth.RefreshToken,
        UserId = auth.User.Id.ToString(),
        Email = auth.User.Email,
        DisplayName = auth.User.UserMetadata?.DisplayName,
        ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(auth.ExpiresIn),
    };

    private void SetSession(SupabaseSession? session)
    {
        _session = session;
        CachedAccessToken = session?.AccessToken ?? "";
        if (session is null) SecureSessionStore.Clear();
        else SecureSessionStore.Save(session);
        SessionChanged?.Invoke(session);
    }
}
