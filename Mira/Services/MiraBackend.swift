import Foundation

// Routes provider API calls through Mira's backend (Supabase edge functions)
// instead of embedding secret keys in the client binary. See
// docs/architecture/backend_secrets_proxy.md.
//
// `useProxy == false` keeps the legacy behavior EXACTLY: direct calls to the
// provider with the embedded key. Flip it to true only once the edge functions
// are deployed and their secrets are set server-side. Call sites are written so
// the swap is a no-op until then.
enum MiraBackend {

    /// Master switch. false = legacy direct calls (current). true = route through
    /// the backend proxy with the signed-in user's Supabase JWT.
    static let useProxy = true

    private static var functionsBase: String { "\(AppSecrets.supabaseURL)/functions/v1" }

    /// Error surfaced when proxy mode is on but no user is signed in. Call sites
    /// can map this to a sign-in prompt.
    enum BackendError: Error { case notSignedIn }

    // MARK: - Anthropic

    /// Where Anthropic message requests go: the proxy in proxy mode, Anthropic
    /// directly otherwise. Request bodies are identical either way (the proxy is
    /// transparent), so callers only change the URL + auth.
    static var anthropicMessagesURL: URL {
        useProxy
            ? URL(string: "\(functionsBase)/anthropic-proxy")!
            : URL(string: "https://api.anthropic.com/v1/messages")!
    }

    /// Applies the correct auth to an Anthropic request:
    ///  - proxy mode → `Authorization: Bearer <supabase JWT>` (the real key lives
    ///    only on the server). Returns false if there's no signed-in session.
    ///  - direct mode → the legacy `x-api-key` header. Always returns true.
    @discardableResult
    static func authorizeAnthropic(_ req: inout URLRequest, directKey: String) -> Bool {
        if useProxy {
            let jwt = SupabaseService.cachedAccessToken
            guard !jwt.isEmpty else { return false }
            req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        } else {
            req.setValue(directKey, forHTTPHeaderField: "x-api-key")
        }
        return true
    }

    // MARK: - OpenAI (chat/completions)

    static var openAIChatURL: URL {
        useProxy
            ? URL(string: "\(functionsBase)/openai-proxy")!
            : URL(string: "https://api.openai.com/v1/chat/completions")!
    }

    /// OpenAI uses `Authorization: Bearer …` in both modes — the proxy swaps the
    /// value (user JWT) for the secret server-side. Returns false in proxy mode
    /// when there's no signed-in session.
    @discardableResult
    static func authorizeOpenAI(_ req: inout URLRequest, directKey: String) -> Bool {
        if useProxy {
            let jwt = SupabaseService.cachedAccessToken
            guard !jwt.isEmpty else { return false }
            req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        } else {
            req.setValue("Bearer \(directKey)", forHTTPHeaderField: "Authorization")
        }
        return true
    }

    // MARK: - OpenAI (text-to-speech / voice previews)

    /// Where the voice-preview TTS request goes: the proxy in proxy mode (the
    /// client sends only the voice; the phrase + key live server-side), else
    /// OpenAI's speech endpoint directly.
    static var openAITTSURL: URL {
        useProxy
            ? URL(string: "\(functionsBase)/openai-tts-proxy")!
            : URL(string: "https://api.openai.com/v1/audio/speech")!
    }

    /// Bearer value for the realtime token-mint edge function: the user's JWT when
    /// signed in, else the anon key (keeps unauthenticated direct-mode calls working
    /// until proxy mode is on and sign-in is required).
    static var supabaseBearer: String {
        let jwt = SupabaseService.cachedAccessToken
        return jwt.isEmpty ? AppSecrets.supabaseAnonKey : jwt
    }

    // MARK: - AssemblyAI

    /// Base for AssemblyAI's REST API — the path-forwarding proxy in proxy mode
    /// (callers append the same /v2/* paths), else AssemblyAI directly.
    static var assemblyAIBaseURL: String {
        useProxy ? "\(functionsBase)/assemblyai-proxy" : "https://api.assemblyai.com"
    }

    /// AssemblyAI uses the raw key in `Authorization` (no Bearer). In proxy mode we
    /// send the user's JWT (Bearer); the server swaps in the real key.
    @discardableResult
    static func authorizeAssemblyAI(_ req: inout URLRequest, directKey: String) -> Bool {
        if useProxy {
            let jwt = SupabaseService.cachedAccessToken
            guard !jwt.isEmpty else { return false }
            req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        } else {
            req.setValue(directKey, forHTTPHeaderField: "Authorization")
        }
        return true
    }

    /// Edge function that mints a short-lived AssemblyAI streaming token.
    static var assemblyAITokenURL: URL { URL(string: "\(functionsBase)/mint-assemblyai-token")! }

    // MARK: - Spotify

    /// Edge function that resolves a track/artist query to a playable Spotify URI
    /// via the Web API (Client Credentials). Keeps the Spotify client secret server-side.
    static var spotifySearchURL: URL { URL(string: "\(functionsBase)/spotify-search")! }
}
