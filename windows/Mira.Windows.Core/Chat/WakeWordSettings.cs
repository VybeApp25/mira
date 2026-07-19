using Mira.Windows.Core.Storage;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Chat;

/// <summary>
/// The Windows equivalent of macOS's <c>mira_wake_word_enabled</c> UserDefaults
/// flag (WakeWordService.swift's <c>isEnabledPreference</c>) — defaults ON so
/// existing behavior is preserved when the key was never written, exactly like
/// Mac's "key absent means true" check.
/// </summary>
public static class WakeWordSettings
{
    private const string FileName = "wake_word.json";

    /// <summary>Mirrors WakeWordService.swift's <c>triggers</c> array verbatim, including the common mishearings.</summary>
    public static readonly string[] Triggers = ["hey mira", "hey mirror", "hey mirra", "okay mira", "hi mira"];

    public static bool IsEnabled
    {
        get
        {
            var path = LocalAppData.PathFor(FileName);
            if (!File.Exists(path)) return true;
            try { return (bool?)JObject.Parse(File.ReadAllText(path))["wake_word_enabled"] ?? true; }
            catch { return true; }
        }
        set
        {
            var json = new JObject { ["wake_word_enabled"] = value }.ToString(Newtonsoft.Json.Formatting.None);
            File.WriteAllText(LocalAppData.PathFor(FileName), json);
        }
    }

    /// <summary>Mirrors WakeWordService.swift's recognition-task callback: <c>triggers.contains(where: { text.contains($0) })</c> on the lowercased transcription.</summary>
    public static bool MatchesTrigger(string? recognizedText)
    {
        if (string.IsNullOrWhiteSpace(recognizedText)) return false;
        var lowered = recognizedText.ToLowerInvariant();
        return Triggers.Any(lowered.Contains);
    }
}
