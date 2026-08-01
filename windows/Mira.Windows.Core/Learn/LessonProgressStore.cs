using Mira.Windows.Core.Storage;
using Newtonsoft.Json;

namespace Mira.Windows.Core.Learn;

/// <summary>One lesson's progress -- mirrors what <c>LearnerModel.swift</c> derives from the telemetry journal, but stored directly (see class doc below for why).</summary>
public sealed class LessonProgress
{
    public required string LessonId { get; init; }
    public int CompletionCount { get; set; }
    public DateTimeOffset? LastCompletedAt { get; set; }

    /// <summary>Resume anchor for an unfinished run -- the index of the next step to show. -1 means never started; reset to 0 once a run completes (mirrors Mac's own "no anchor once mastered/finished" behavior).</summary>
    public int ResumeStepIndex { get; set; } = -1;
}

/// <summary>
/// The Windows equivalent of Mira/Services/LearnerModel.swift -- with one
/// deliberate architecture difference: Mac's version is fully DERIVED from
/// an append-only telemetry journal (<c>TelemetryService</c>), never itself
/// persisted. Windows has no telemetry journal yet (no other ported feature
/// needed one), and building a whole event-log subsystem just to make this
/// one store re-derivable would be scope creep for a first pass. This store
/// persists <see cref="LessonProgress"/> directly per lesson instead --
/// same mastery math, same resume/review semantics, different storage
/// shape. If a real telemetry journal gets built for another feature later,
/// this could be re-derived from it instead without changing its public API.
/// </summary>
public sealed class LessonProgressStore
{
    public static LessonProgressStore Shared { get; } = new();

    private const string FileName = "lesson_progress.json";
    public const double MasteryThreshold = 0.80;
    private const int ReviewDueAfterDays = 7;

    private readonly Dictionary<string, LessonProgress> _progress = new();
    private readonly object _gate = new();

    public event Action? Changed;

    private LessonProgressStore() => Load();

    public LessonProgress Get(string lessonId)
    {
        lock (_gate)
        {
            if (_progress.TryGetValue(lessonId, out var existing)) return Clone(existing);
            return new LessonProgress { LessonId = lessonId };
        }
    }

    public void RecordStepCompleted(string lessonId, int finishedStepIndex)
    {
        lock (_gate)
        {
            var progress = GetOrCreateLocked(lessonId);
            progress.ResumeStepIndex = finishedStepIndex + 1;
        }
        Persist();
        Changed?.Invoke();
    }

    public void RecordLessonCompleted(string lessonId, DateTimeOffset now)
    {
        lock (_gate)
        {
            var progress = GetOrCreateLocked(lessonId);
            progress.CompletionCount++;
            progress.LastCompletedAt = now;
            progress.ResumeStepIndex = -1;
        }
        Persist();
        Changed?.Invoke();
    }

    /// <summary>Pure -- mirrors <c>LearnerModel</c>'s mastery curve (<c>1 - 0.45^completions</c>): each completion buys down the remaining "not yet mastered" probability by 55%.</summary>
    public static double MasteryScore(int completions) => 1 - Math.Pow(0.45, completions);

    public static bool IsMastered(int completions) => MasteryScore(completions) >= MasteryThreshold;

    /// <summary>Pure -- mastered but stale (mirrors Mac's &gt;7-day-since-last-completion review nudge).</summary>
    public static bool IsReviewDue(int completions, DateTimeOffset? lastCompletedAt, DateTimeOffset now) =>
        IsMastered(completions) && lastCompletedAt is { } last && (now - last).TotalDays > ReviewDueAfterDays;

    private LessonProgress GetOrCreateLocked(string lessonId)
    {
        if (!_progress.TryGetValue(lessonId, out var progress))
        {
            progress = new LessonProgress { LessonId = lessonId };
            _progress[lessonId] = progress;
        }
        return progress;
    }

    private static LessonProgress Clone(LessonProgress p) => new()
    {
        LessonId = p.LessonId,
        CompletionCount = p.CompletionCount,
        LastCompletedAt = p.LastCompletedAt,
        ResumeStepIndex = p.ResumeStepIndex,
    };

    private void Persist()
    {
        List<LessonProgress> snapshot;
        lock (_gate) snapshot = _progress.Values.ToList();
        try { File.WriteAllText(LocalAppData.PathFor(FileName), JsonConvert.SerializeObject(snapshot)); }
        catch { /* best-effort persistence */ }
    }

    private void Load()
    {
        try
        {
            var path = LocalAppData.PathFor(FileName);
            if (!File.Exists(path)) return;
            var list = JsonConvert.DeserializeObject<List<LessonProgress>>(File.ReadAllText(path));
            if (list is null) return;
            foreach (var p in list) _progress[p.LessonId] = p;
        }
        catch
        {
            // Corrupt/missing file -- start fresh rather than throwing on construction.
        }
    }
}
