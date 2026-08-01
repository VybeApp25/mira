using Mira.Windows.Core.Storage;
using Newtonsoft.Json;

namespace Mira.Windows.Core.Crons;

/// <summary>
/// The Windows equivalent of Mira/Models/CronModels.swift's <c>CronStore</c> —
/// JSON-persisted locally (Mac uses UserDefaults; same idea, different
/// storage), no Supabase table involved. No plan gating either: confirmed by
/// reading CronsTabView.swift, CronScheduler.swift, and CronModels.swift in
/// full — none of them reference <c>EntitlementService</c> at all, unlike
/// Agents/Skills. Unlike those two, this feature really is open to every
/// plan on Mac, so this port doesn't invent a gate that doesn't exist there.
/// </summary>
public sealed class CronStore
{
    public static CronStore Shared { get; } = new();

    private const string FileName = "crons.json";

    private readonly List<MiraCron> _crons = new();
    private readonly object _gate = new();

    public event Action? Changed;

    private CronStore() => Load();

    public IReadOnlyList<MiraCron> Crons { get { lock (_gate) return _crons.ToList(); } }

    public void Add(MiraCron cron)
    {
        lock (_gate) _crons.Add(cron);
        Persist();
        Changed?.Invoke();
    }

    public void Update(MiraCron cron)
    {
        lock (_gate)
        {
            var idx = _crons.FindIndex(c => c.Id == cron.Id);
            if (idx < 0) return;
            _crons[idx] = cron;
        }
        Persist();
        Changed?.Invoke();
    }

    public void Delete(Guid id)
    {
        lock (_gate) _crons.RemoveAll(c => c.Id == id);
        Persist();
        Changed?.Invoke();
    }

    public void Toggle(Guid id)
    {
        lock (_gate)
        {
            var cron = _crons.FirstOrDefault(c => c.Id == id);
            if (cron is null) return;
            cron.Enabled = !cron.Enabled;
        }
        Persist();
        Changed?.Invoke();
    }

    public void RecordRun(Guid id, string result, DateTimeOffset now)
    {
        lock (_gate)
        {
            var cron = _crons.FirstOrDefault(c => c.Id == id);
            if (cron is null) return;
            cron.LastRunAt = now;
            cron.LastRunResult = result;
            cron.NextFireAt = cron.Schedule.NextFire(now);
        }
        Persist();
        Changed?.Invoke();
    }

    public IReadOnlyList<MiraCron> DueCrons(DateTimeOffset now) => ComputeDue(Crons, now);

    /// <summary>
    /// The pure due-cron filter, extracted so it's directly unit-testable
    /// without touching the live singleton or the real clock — same
    /// "extract for testability" pattern as
    /// <see cref="Agents.AgentJobStore.CheckCanSubmit"/> and
    /// <see cref="Shelf.FileShelfStore.DisambiguateName"/>. Mirrors
    /// <c>CronStore.dueCrons</c>.
    /// </summary>
    public static IReadOnlyList<MiraCron> ComputeDue(IEnumerable<MiraCron> crons, DateTimeOffset now) =>
        crons.Where(c => c.Enabled && c.NextFireAt <= now).ToList();

    private void Persist()
    {
        List<MiraCron> snapshot;
        lock (_gate) snapshot = _crons.ToList();
        try { File.WriteAllText(LocalAppData.PathFor(FileName), JsonConvert.SerializeObject(snapshot)); }
        catch { /* best-effort persistence */ }
    }

    private void Load()
    {
        try
        {
            var path = LocalAppData.PathFor(FileName);
            if (!File.Exists(path)) return;
            var crons = JsonConvert.DeserializeObject<List<MiraCron>>(File.ReadAllText(path));
            if (crons is not null) _crons.AddRange(crons);
        }
        catch
        {
            // Corrupt/missing history file -- start fresh rather than throwing on construction.
        }
    }
}
