using Mira.Windows.Core.Storage;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Voice;

/// <summary>
/// The Windows equivalent of macOS's <c>MiraVoice</c> enum
/// (<c>RealtimeVoiceService.swift</c>) -- the 10 OpenAI Realtime voices Mira can
/// speak with. The selected voice is sent both when minting the ephemeral
/// Realtime token (<c>mint-realtime-token</c>'s optional <c>voice</c> field)
/// and in every <c>session.update</c>'s <c>audio.output.voice</c>.
/// </summary>
public enum MiraVoice
{
    Alloy,
    Ash,
    Ballad,
    Cedar,
    Coral,
    Echo,
    Marin,
    Sage,
    Shimmer,
    Verse,
}

public static class MiraVoiceExtensions
{
    /// <summary>The id sent to OpenAI -- matches the Swift original's <c>rawValue</c> exactly.</summary>
    public static string Id(this MiraVoice voice) => voice switch
    {
        MiraVoice.Alloy => "alloy",
        MiraVoice.Ash => "ash",
        MiraVoice.Ballad => "ballad",
        MiraVoice.Cedar => "cedar",
        MiraVoice.Coral => "coral",
        MiraVoice.Echo => "echo",
        MiraVoice.Marin => "marin",
        MiraVoice.Sage => "sage",
        MiraVoice.Shimmer => "shimmer",
        MiraVoice.Verse => "verse",
        _ => "alloy",
    };

    /// <summary>Matches the Swift original's <c>label</c> exactly.</summary>
    public static string Label(this MiraVoice voice) => voice switch
    {
        MiraVoice.Alloy => "Alloy — Neutral",
        MiraVoice.Ash => "Ash — Calm",
        MiraVoice.Ballad => "Ballad — Warm",
        MiraVoice.Cedar => "Cedar — Grounded",
        MiraVoice.Coral => "Coral — Bright",
        MiraVoice.Echo => "Echo — Crisp",
        MiraVoice.Marin => "Marin — Clear",
        MiraVoice.Sage => "Sage — Measured",
        MiraVoice.Shimmer => "Shimmer — Soft",
        MiraVoice.Verse => "Verse — Expressive",
        _ => voice.ToString(),
    };
}

/// <summary>Persisted selected voice, "alloy" by default -- matches <c>MiraVoice.saved</c>'s own UserDefaults default.</summary>
public static class MiraVoiceSettings
{
    private const string FileName = "mira_voice.json";

    public static MiraVoice Saved
    {
        get
        {
            var path = LocalAppData.PathFor(FileName);
            if (!File.Exists(path)) return MiraVoice.Alloy;
            try
            {
                var id = (string?)JObject.Parse(File.ReadAllText(path))["voice"];
                return id is not null && Enum.TryParse<MiraVoice>(id, ignoreCase: true, out var v) ? v : MiraVoice.Alloy;
            }
            catch { return MiraVoice.Alloy; }
        }
        set
        {
            var json = new JObject { ["voice"] = value.Id() }.ToString(Newtonsoft.Json.Formatting.None);
            File.WriteAllText(LocalAppData.PathFor(FileName), json);
        }
    }
}
