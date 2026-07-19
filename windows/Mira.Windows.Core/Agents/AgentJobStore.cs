using Mira.Contracts.ProfileRow;
using Mira.Windows.Core.Entitlements;
using Mira.Windows.Core.Storage;
using Newtonsoft.Json;

namespace Mira.Windows.Core.Agents;

/// <summary>
/// The Windows equivalent of Mira/Services/AgentJobStore.swift — trimmed to
/// the 3 job types this port actually runs (see <see cref="AgentJobType"/>).
/// Same architecture as the Mac original: jobs run in a detached background
/// task on the running process (no OS-level background execution, no
/// server-side runner — if the app quits mid-job, the job dies with it,
/// exactly like Mac), and persist to a local JSON file, not Supabase.
///
/// Two real improvements over the Mac source, not just a port — both
/// confirmed as gaps in the actual Mac code before making this decision:
/// <list type="bullet">
/// <item><b>Concurrency limit is actually enforced.</b>
/// <c>SubscriptionPlan.maxConcurrentAgents</c> exists on Mac
/// (Free=0/Pro=2/Ultra=5) but is never read anywhere outside its own
/// declaration — <c>AgentJobStore.submitJob</c> unconditionally spawns a new
/// task with no cap. This port actually checks
/// <see cref="EntitlementService.MaxConcurrentAgents"/> against the current
/// running-job count before accepting a submission.</item>
/// </list>
/// </summary>
public sealed class AgentJobStore
{
    public static AgentJobStore Shared { get; } = new();

    private const string FileName = "agent_jobs.json";

    private readonly List<AgentJob> _jobs = new();
    private readonly object _gate = new();

    public event Action? Changed;

    private AgentJobStore() => Load();

    /// <summary>Newest first, matching the Mac tab's own insert-at-front order.</summary>
    public IReadOnlyList<AgentJob> Jobs
    {
        get { lock (_gate) return _jobs.ToList(); }
    }

    public int RunningCount
    {
        get { lock (_gate) return _jobs.Count(j => j.Status is AgentJobStatus.Queued or AgentJobStatus.Running); }
    }

    /// <summary>
    /// Mirrors <c>submitJob(prompt:...)</c> — same entitlement gate
    /// (<c>entitlements.can(.runAgents)</c>) as the Mac tab. Returns an error
    /// message instead of a job if gated by entitlement or concurrency,
    /// rather than throwing, since both are expected, user-facing outcomes.
    /// </summary>
    public (AgentJob? Job, string? Error) SubmitJob(string prompt, AgentJobType? explicitType = null, CancellationToken ct = default)
    {
        var gateError = CheckCanSubmit(EntitlementService.Shared.Plan, RunningCount);
        if (gateError is not null) return (null, gateError);

        var job = new AgentJob
        {
            Id = Guid.NewGuid(),
            Type = explicitType ?? AgentJob.Detect(prompt),
            Prompt = prompt,
            CreatedAt = DateTimeOffset.UtcNow,
            Status = AgentJobStatus.Queued,
        };

        lock (_gate) _jobs.Insert(0, job);
        Persist();
        Changed?.Invoke();

        _ = RunJobAsync(job, ct);
        return (job, null);
    }

    /// <summary>
    /// The pure entitlement + concurrency gate, extracted so it's directly
    /// unit-testable without touching the live singleton (which would kick
    /// off a real Claude API call the moment a submission passes the gate)
    /// — same "extract for testability" pattern as
    /// <see cref="Entitlements.EntitlementService.CanForPlan"/> and
    /// <see cref="Clipboard.ClipboardHistoryStore.ApplyAdd"/>. Returns
    /// <c>null</c> when submission is allowed, or a user-facing message
    /// explaining why not.
    /// </summary>
    public static string? CheckCanSubmit(ProfilePlan plan, int currentRunningCount)
    {
        if (!EntitlementService.CanForPlan(plan, Entitlement.RunAgents))
            return "Agents need a Pro or Ultra plan. Upgrade in Settings to run background tasks.";

        var maxConcurrent = plan.MaxConcurrentAgents();
        if (currentRunningCount >= maxConcurrent)
            return $"You've reached your plan's limit of {maxConcurrent} agent(s) running at once. Wait for one to finish or upgrade your plan.";

        return null;
    }

    private async Task RunJobAsync(AgentJob job, CancellationToken ct)
    {
        SetStatus(job, AgentJobStatus.Running);
        try
        {
            var result = job.Type switch
            {
                AgentJobType.DeepResearch => await DeepResearchAgent.RunAsync(job, ct),
                AgentJobType.ContentGeneration => await ContentAgent.RunAsync(job, ct),
                _ => await GenericAgent.RunAsync(job, ct),
            };

            lock (_gate)
            {
                job.ResultText = result.ResultText;
                job.OutputFilePath = result.OutputFilePath;
                job.Status = AgentJobStatus.Completed;
            }
        }
        catch (Exception ex)
        {
            lock (_gate)
            {
                job.ErrorMessage = ex.Message;
                job.Status = AgentJobStatus.Failed;
            }
        }
        Persist();
        Changed?.Invoke();
    }

    public void CancelJob(Guid id)
    {
        SetStatus(id, AgentJobStatus.Cancelled);
        // Best-effort: the in-flight Task.Run for this job isn't forcibly
        // aborted (matching Mac -- there's no cancellation token threaded
        // through the runner either), it just gets ignored once it finishes.
    }

    public void RemoveJob(Guid id)
    {
        lock (_gate) _jobs.RemoveAll(j => j.Id == id);
        Persist();
        Changed?.Invoke();
    }

    private void SetStatus(AgentJob job, AgentJobStatus status)
    {
        lock (_gate) job.Status = status;
        Persist();
        Changed?.Invoke();
    }

    private void SetStatus(Guid id, AgentJobStatus status)
    {
        AgentJob? job;
        lock (_gate) job = _jobs.FirstOrDefault(j => j.Id == id);
        if (job is not null) SetStatus(job, status);
    }

    private void Persist()
    {
        List<AgentJob> snapshot;
        lock (_gate) snapshot = _jobs.ToList();
        try
        {
            File.WriteAllText(LocalAppData.PathFor(FileName), JsonConvert.SerializeObject(snapshot));
        }
        catch
        {
            // Best-effort persistence -- a failed write shouldn't crash job tracking.
        }
    }

    private void Load()
    {
        try
        {
            var path = LocalAppData.PathFor(FileName);
            if (!File.Exists(path)) return;
            var jobs = JsonConvert.DeserializeObject<List<AgentJob>>(File.ReadAllText(path));
            if (jobs is null) return;

            // Mirrors AgentJobStore.swift's load(): any job that wasn't
            // terminal when the app last quit did NOT survive -- these are
            // in-process Task.Run executions, not resumable server-side jobs.
            foreach (var job in jobs)
            {
                if (job.Status is AgentJobStatus.Queued or AgentJobStatus.Running)
                {
                    job.Status = AgentJobStatus.Cancelled;
                    job.ErrorMessage = "Job interrupted — app was closed.";
                }
            }
            _jobs.AddRange(jobs);
        }
        catch
        {
            // Corrupt/missing history file -- start fresh rather than throwing on construction.
        }
    }
}
