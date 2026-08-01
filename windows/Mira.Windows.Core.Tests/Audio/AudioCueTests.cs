using Mira.Windows.Core.Audio;
using Xunit;

namespace Mira.Windows.Core.Tests.Audio;

public class AudioCueTests
{
    [Theory]
    [InlineData(MiraSound.AgentLaunch, "agent-launch", "mp3")]
    [InlineData(MiraSound.AgentDone, "agent-done", "mp3")]
    [InlineData(MiraSound.AgentClose, "agent-close", "mp3")]
    [InlineData(MiraSound.Enter, "enter", "mp3")]
    [InlineData(MiraSound.TextOpen, "clicky-text-open", "wav")]
    [InlineData(MiraSound.TextSend, "clicky-text-send", "wav")]
    [InlineData(MiraSound.TextReceive, "clicky-text-receive", "wav")]
    [InlineData(MiraSound.TextClose, "clicky-text-close", "wav")]
    [InlineData(MiraSound.SkillUp, "skill-up", "wav")]
    [InlineData(MiraSound.SkillDown, "skill-down", "wav")]
    [InlineData(MiraSound.Question, "clicky-question", "wav")]
    [InlineData(MiraSound.Surprised, "clicky-surprised", "wav")]
    [InlineData(MiraSound.ConnectionQuestion, "connection-question", "wav")]
    [InlineData(MiraSound.Eshop, "eshop", "mp3")]
    [InlineData(MiraSound.Ff, "ff", "mp3")]
    [InlineData(MiraSound.Hatching, "hatching", "wav")]
    public void FileNameAndExtension_MatchMacExactly(MiraSound sound, string expectedName, string expectedExt)
    {
        Assert.Equal(expectedName, sound.FileName());
        Assert.Equal(expectedExt, sound.FileExtension());
    }

    [Fact]
    public void AudioCueSettings_MuteRoundTrips()
    {
        var original = AudioCueSettings.IsMuted;
        try
        {
            AudioCueSettings.IsMuted = true;
            Assert.True(AudioCueSettings.IsMuted);
            AudioCueSettings.IsMuted = false;
            Assert.False(AudioCueSettings.IsMuted);
        }
        finally
        {
            AudioCueSettings.IsMuted = original;
        }
    }

    [Fact]
    public void AudioCueSettings_PerCueEnabled_DefaultsTrueAndRoundTrips()
    {
        const string cue = "test-cue-xyz";
        Assert.True(AudioCueSettings.IsCueEnabled(cue));

        AudioCueSettings.SetCueEnabled(cue, false);
        Assert.False(AudioCueSettings.IsCueEnabled(cue));

        AudioCueSettings.SetCueEnabled(cue, true);
        Assert.True(AudioCueSettings.IsCueEnabled(cue));
    }

    [Fact]
    public void AudioCueService_ConstructsAndPlaysWithoutThrowing_EvenWithoutSoundFilesPresent()
    {
        // The test host's own output directory has no Assets/Sounds folder --
        // confirms Preload()'s missing-file handling degrades to silence rather
        // than throwing, matching the Swift original's own "if let ... try? ..." pattern.
        AudioCueService.Shared.Play(MiraSound.Enter);
        AudioCueService.Shared.PlayTextOpen();
        AudioCueService.Shared.PlayVoiceStart();
    }
}
