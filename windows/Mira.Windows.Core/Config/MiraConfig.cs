namespace Mira.Windows.Core.Config;

/// <summary>
/// Non-secret client configuration — the Windows equivalent of the tail end of
/// macOS's <c>AppSecrets.swift</c> after the backend-secrets-proxy migration
/// (see docs/windows/SECURITY_AND_PRIVACY.md): only the Supabase project URL and
/// the Supabase *anon* key, both public by design (the anon key identifies the
/// project, not a user or a secret capability — see supabase/functions/_shared/auth.ts,
/// which never treats it as an authorization credential; every real permission
/// check happens against the caller's JWT instead).
///
/// No provider API keys (Anthropic/OpenAI/AssemblyAI/Composio/Stripe/Miso) belong
/// here or anywhere in this client — see SECURITY_AND_PRIVACY.md §7.
/// </summary>
public static class MiraConfig
{
    /// <summary>
    /// Supabase project URL. Matches the value baked into the macOS client's
    /// AppSecrets.swift (confirmed indirectly via supabase/migrations' hardcoded
    /// project ref <c>rdbljrbjsmbfqwwpwwvn</c>, e.g. in the spend-alarm pg_cron job
    /// and appcast.xml's SUFeedURL).
    /// </summary>
    public const string SupabaseUrl = "https://rdbljrbjsmbfqwwpwwvn.supabase.co";

    /// <summary>
    /// Supabase anon (public) API key. TODO before any real build/distribution:
    /// fill in the actual anon key value (safe to embed — see class doc). Left
    /// blank here deliberately rather than guessed, since this audit's source
    /// checkout never contained the gitignored Mira/Config/AppSecrets.swift that
    /// holds it on the macOS side — see docs/windows/SECURITY_AND_PRIVACY.md §1.
    /// </summary>
    public const string SupabaseAnonKey = "";
}
