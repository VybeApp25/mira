namespace Mira.Windows.Core.Audio;

/// <summary>Mirrors AudioCueService.swift's <c>MiraSound</c> enum exactly -- same 16 cues, same underlying file names and extensions.</summary>
public enum MiraSound
{
    // Agent lifecycle
    AgentLaunch,
    AgentDone,
    AgentClose,
    // Interaction
    Enter,
    TextOpen,
    TextSend,
    TextReceive,
    TextClose,
    SkillUp,
    SkillDown,
    // State cues
    Question,
    Surprised,
    ConnectionQuestion,
    // Ambient
    Eshop,
    Ff,
    Hatching,
}

public static class MiraSoundExtensions
{
    /// <summary>The bundled file name (without extension) -- matches the Swift enum's raw value exactly.</summary>
    public static string FileName(this MiraSound sound) => sound switch
    {
        MiraSound.AgentLaunch => "agent-launch",
        MiraSound.AgentDone => "agent-done",
        MiraSound.AgentClose => "agent-close",
        MiraSound.Enter => "enter",
        MiraSound.TextOpen => "clicky-text-open",
        MiraSound.TextSend => "clicky-text-send",
        MiraSound.TextReceive => "clicky-text-receive",
        MiraSound.TextClose => "clicky-text-close",
        MiraSound.SkillUp => "skill-up",
        MiraSound.SkillDown => "skill-down",
        MiraSound.Question => "clicky-question",
        MiraSound.Surprised => "clicky-surprised",
        MiraSound.ConnectionQuestion => "connection-question",
        MiraSound.Eshop => "eshop",
        MiraSound.Ff => "ff",
        MiraSound.Hatching => "hatching",
        _ => throw new ArgumentOutOfRangeException(nameof(sound)),
    };

    /// <summary>Matches the Swift enum's exact per-case file extension.</summary>
    public static string FileExtension(this MiraSound sound) => sound switch
    {
        MiraSound.AgentLaunch or MiraSound.AgentDone or MiraSound.AgentClose
            or MiraSound.Enter or MiraSound.Eshop or MiraSound.Ff => "mp3",
        _ => "wav",
    };
}
