namespace Mira.Windows.Core.Auth;

/// <summary>
/// The Windows equivalent of macOS's <c>SupabaseError</c> enum
/// (Mira/Services/SupabaseService.swift) — collapsed to one exception type with a
/// status code, since C# exceptions don't need Swift's exhaustive-switch ergonomics.
/// </summary>
public sealed class SupabaseAuthException : Exception
{
    /// <summary>HTTP status code, or <c>null</c> for a transport-level failure (no response at all).</summary>
    public int? StatusCode { get; }

    public SupabaseAuthException(string message, int? statusCode = null, Exception? inner = null)
        : base(message, inner)
    {
        StatusCode = statusCode;
    }

    public static SupabaseAuthException FromErrorBody(int statusCode, string body)
    {
        // GoTrue error bodies are typically {"error":"...","error_description":"..."} or
        // {"msg":"..."} depending on the endpoint — try a couple of common shapes before
        // falling back to the raw body, mirroring SupabaseService.swift's best-effort
        // `(try? JSONSerialization...)?["message"] as? String ?? raw body` fallback chain.
        string message = body;
        try
        {
            var obj = Newtonsoft.Json.Linq.JObject.Parse(body);
            message = (string?)(obj["error_description"] ?? obj["msg"] ?? obj["message"] ?? obj["error"]) ?? body;
        }
        catch (Newtonsoft.Json.JsonException)
        {
            // not JSON — use the raw body as-is
        }
        return new SupabaseAuthException(message, statusCode);
    }
}
