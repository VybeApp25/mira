namespace Mira.Windows.Core.Entitlements;

/// <summary>Mirrors macOS's <c>Entitlement</c> enum (Mira/Services/EntitlementService.swift).</summary>
public enum Entitlement
{
    RunAgents,
    BuildWebsites,
    BuildApps,
    UseVoiceMode,
    UseScreenGuidance,
    DeepResearch,
    ContentGeneration,
    UnlimitedChat,
    /// <summary>View/toggle built-in skills — mirrors Mac's Pro-tier <c>allowedSkillOrigins = [.builtin, .platform]</c>.</summary>
    ViewSkills,
    /// <summary>Import a local SKILL.md or generate one via Claude — mirrors Mac's Ultra-only <c>.user</c> origin.</summary>
    CreateSkills,
}
