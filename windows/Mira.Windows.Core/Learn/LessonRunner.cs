namespace Mira.Windows.Core.Learn;

public enum LessonRunState { Idle, Running, Completed }

/// <summary>
/// The Windows equivalent of the reachable slice of Mira/Services/TeachingEngine.swift
/// -- the step-advancing state machine, trimmed to deterministic checks only
/// (no vision-grounding annotation, no vision-observed steps, no autonomous
/// mode; see docs/windows/IMPLEMENTATION_PLAN.md's Learn section for why).
/// Polls the current step's check once a second via a plain
/// <see cref="System.Threading.Timer"/> (Core has no WPF dependency to hang
/// a DispatcherTimer off, same reasoning as <see cref="Crons.CronScheduler"/>)
/// and auto-advances when satisfied; a <see cref="LessonCheckKind.UserConfirmation"/>
/// step instead waits for an explicit <see cref="ConfirmCurrentStep"/> call --
/// mirrors the "no self-certify button for an observable step" honesty
/// invariant that's the whole design's organizing principle on Mac.
/// </summary>
public sealed class LessonRunner
{
    public static LessonRunner Shared { get; } = new();

    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(1);

    private readonly object _gate = new();
    private Timer? _timer;

    public event Action? Changed;

    private LessonRunner() { }

    public Lesson? ActiveLesson { get; private set; }
    public int CurrentStepIndex { get; private set; } = -1;
    public LessonRunState State { get; private set; } = LessonRunState.Idle;

    public LessonStep? CurrentStep
    {
        get
        {
            lock (_gate)
            {
                return ActiveLesson is not null && CurrentStepIndex >= 0 && CurrentStepIndex < ActiveLesson.Steps.Count
                    ? ActiveLesson.Steps[CurrentStepIndex]
                    : null;
            }
        }
    }

    public void Start(Lesson lesson, int fromStepIndex = 0)
    {
        lock (_gate)
        {
            ActiveLesson = lesson;
            CurrentStepIndex = Math.Clamp(fromStepIndex, 0, lesson.Steps.Count - 1);
            State = LessonRunState.Running;
        }
        _timer ??= new Timer(_ => Poll(), null, PollInterval, PollInterval);
        Changed?.Invoke();
    }

    public void Stop()
    {
        lock (_gate)
        {
            ActiveLesson = null;
            CurrentStepIndex = -1;
            State = LessonRunState.Idle;
        }
        _timer?.Dispose();
        _timer = null;
        Changed?.Invoke();
    }

    /// <summary>For a <see cref="LessonCheckKind.UserConfirmation"/> step — the only kind of step a user can self-certify. A no-op for any other check kind, matching Mac's "no self-certify button on an observable step."</summary>
    public void ConfirmCurrentStep()
    {
        if (CurrentStep is not { Check.Kind: LessonCheckKind.UserConfirmation }) return;
        Advance();
    }

    /// <summary>
    /// Recorded identically to a confirmed step in this simplified port —
    /// Mac records a skip as a distinctly-provenanced FAILED telemetry
    /// event; this port has no telemetry journal to record that
    /// distinction into (see <see cref="LessonProgressStore"/>'s own doc
    /// comment), so a skip just advances without incrementing mastery
    /// differently than a genuine completion would.
    /// </summary>
    public void SkipCurrentStep() => Advance();

    private void Poll()
    {
        LessonStep? step;
        lock (_gate) step = State == LessonRunState.Running ? CurrentStep : null;
        if (step is null || !step.Check.IsObservable) return;

        if (IsCheckSatisfied(step.Check, ForegroundApp.GetForegroundProcessName(), DarkMode.IsEnabled()))
            Advance();
    }

    /// <summary>
    /// Pure — the actual satisfied/not-satisfied decision, extracted so
    /// it's directly unit-testable without real Win32/registry calls. Mirrors
    /// <c>SuccessObserver</c>.
    /// </summary>
    public static bool IsCheckSatisfied(LessonCheck check, string? foregroundProcessName, bool darkModeEnabled) => check.Kind switch
    {
        LessonCheckKind.AppFrontmost => foregroundProcessName is not null
            && string.Equals(foregroundProcessName, check.ProcessName, StringComparison.OrdinalIgnoreCase),
        LessonCheckKind.DarkModeEnabled => darkModeEnabled,
        LessonCheckKind.UserConfirmation => false, // never auto-satisfied -- always needs ConfirmCurrentStep()
        _ => false,
    };

    private void Advance()
    {
        Lesson lesson;
        int finishedIndex;
        int nextIndex;
        lock (_gate)
        {
            if (ActiveLesson is null) return;
            lesson = ActiveLesson;
            finishedIndex = CurrentStepIndex;
            CurrentStepIndex++;
            nextIndex = CurrentStepIndex;
        }

        LessonProgressStore.Shared.RecordStepCompleted(lesson.Id, finishedIndex);

        if (nextIndex >= lesson.Steps.Count)
        {
            LessonProgressStore.Shared.RecordLessonCompleted(lesson.Id, DateTimeOffset.UtcNow);
            lock (_gate) State = LessonRunState.Completed;
        }

        Changed?.Invoke();
    }
}
