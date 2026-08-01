using Mira.Windows.Core.Audio;
using Mira.Windows.Core.Storage;
using Newtonsoft.Json;

namespace Mira.Windows.Core.Skills;

/// <summary>
/// The Windows equivalent of Mira/Services/SkillStore.swift — tracks which
/// skills are toggled on and builds the concatenated context string spliced
/// into chat system prompts (see <see cref="Chat.RouterHandler"/>). Purely
/// local: active-skill-id set persisted as JSON (Mac uses UserDefaults;
/// same idea, different storage), user skill folders loaded via
/// <see cref="MiraSkillLoader"/>. No Supabase involvement, matching Mac.
/// </summary>
public sealed class SkillStore
{
    public static SkillStore Shared { get; } = new();

    private const string ActiveIdsFileName = "active_skill_ids.json";

    private readonly List<MiraSkill> _userSkills;
    private readonly HashSet<string> _activeIds;

    public event Action? Changed;

    private SkillStore()
    {
        _userSkills = MiraSkillLoader.LoadUserSkills();
        _activeIds = LoadActiveIds();
    }

    /// <summary>Built-ins first, then user skills — matches the Mac tab's own display order.</summary>
    public IReadOnlyList<MiraSkill> All => MiraSkillCatalog.Builtins.Concat(_userSkills).ToList();

    public bool IsActive(string id) => _activeIds.Contains(id);

    public void Toggle(string id)
    {
        var willActivate = !_activeIds.Contains(id);
        if (!_activeIds.Add(id)) _activeIds.Remove(id);
        PersistActiveIds();
        AudioCueService.Shared.Play(willActivate ? MiraSound.SkillUp : MiraSound.SkillDown);
        Changed?.Invoke();
    }

    public void Refresh()
    {
        _userSkills.Clear();
        _userSkills.AddRange(MiraSkillLoader.LoadUserSkills());
        Changed?.Invoke();
    }

    /// <summary>Imports a local SKILL.md file — just text, no code, so no execution-safety concern beyond the same prompt-injection risk any active skill already carries (see IMPLEMENTATION_PLAN.md's Skills section).</summary>
    public (bool Success, string? Error) ImportSkill(string filePath)
    {
        try
        {
            var markdown = File.ReadAllText(filePath);
            var (ok, error) = MiraSkillLoader.SaveUserSkill(markdown, All.Select(s => s.Id).ToList());
            if (ok) Refresh();
            return (ok, error);
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }

    public (bool Success, string? Error) CreateSkill(string markdown)
    {
        var (ok, error) = MiraSkillLoader.SaveUserSkill(markdown, All.Select(s => s.Id).ToList());
        if (ok) Refresh();
        return (ok, error);
    }

    public void RemoveUserSkill(string id)
    {
        MiraSkillLoader.DeleteUserSkill(id);
        _activeIds.Remove(id);
        PersistActiveIds();
        Refresh();
    }

    /// <summary>Concatenated context of every currently-active skill, spliced into the chat system prompt. Empty (never null) when nothing's active, so callers can always append it safely.</summary>
    public string BuildContext() => BuildContextFrom(All, _activeIds);

    /// <summary>
    /// The pure join logic, extracted so it's directly unit-testable without
    /// touching the live singleton's real on-disk active-skill state on this
    /// machine — same "extract for testability" pattern as
    /// <see cref="Agents.AgentJobStore.CheckCanSubmit"/> and
    /// <see cref="Clipboard.ClipboardHistoryStore.ApplyAdd"/>.
    /// </summary>
    public static string BuildContextFrom(IEnumerable<MiraSkill> skills, IReadOnlySet<string> activeIds)
    {
        var active = skills.Where(s => activeIds.Contains(s.Id)).ToList();
        return active.Count == 0 ? "" : string.Join("\n\n", active.Select(s => s.Context));
    }

    private static HashSet<string> LoadActiveIds()
    {
        try
        {
            var path = LocalAppData.PathFor(ActiveIdsFileName);
            if (!File.Exists(path)) return new HashSet<string>();
            var ids = JsonConvert.DeserializeObject<List<string>>(File.ReadAllText(path));
            return ids is null ? new HashSet<string>() : new HashSet<string>(ids);
        }
        catch
        {
            return new HashSet<string>();
        }
    }

    private void PersistActiveIds()
    {
        try { File.WriteAllText(LocalAppData.PathFor(ActiveIdsFileName), JsonConvert.SerializeObject(_activeIds.ToList())); }
        catch { /* best-effort persistence */ }
    }
}
