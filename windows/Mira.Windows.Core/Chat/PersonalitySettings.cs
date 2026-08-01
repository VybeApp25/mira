using Mira.Windows.Core.Storage;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Chat;

/// <summary>
/// The Windows equivalent of macOS's <c>mira_cat_mode</c> UserDefaults flag
/// (SettingsView.swift's Appearance section: "Cat mode 🐱 — Mira responds with
/// feline energy"). Unlike most Appearance toggles ported alongside this one
/// (transparent panes, "show in screen recordings"), Cat Mode has a genuine,
/// verifiable effect reachable from Core: it biases what Claude actually
/// writes back, the same mechanism <see cref="Skills.SkillStore"/> already
/// uses for skill context.
/// </summary>
public static class PersonalitySettings
{
    private const string FileName = "personality.json";

    public static bool CatModeEnabled
    {
        get
        {
            var path = LocalAppData.PathFor(FileName);
            if (!File.Exists(path)) return false;
            try { return (bool?)JObject.Parse(File.ReadAllText(path))["cat_mode_enabled"] ?? false; }
            catch { return false; }
        }
        set
        {
            var json = new JObject { ["cat_mode_enabled"] = value }.ToString(Newtonsoft.Json.Formatting.None);
            File.WriteAllText(LocalAppData.PathFor(FileName), json);
        }
    }

    /// <summary>The instruction spliced into the chat system prompt when Cat Mode is on — mirrors the Mac toggle's own description.</summary>
    public const string CatModeInstruction = "Respond with feline energy: playful, a little aloof, occasional cat puns or a stray \"meow\" for emphasis, but never let it get in the way of actually answering the question.";
}
