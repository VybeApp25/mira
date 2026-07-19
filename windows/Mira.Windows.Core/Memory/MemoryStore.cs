using Mira.Windows.Core.Storage;
using Newtonsoft.Json;

namespace Mira.Windows.Core.Memory;

/// <summary>
/// The Windows equivalent of Mira/Models/MemoryStore.swift — Mira's long-term
/// memory: explicit preferences + observed patterns with confidence scores
/// that reinforce on restatement and decay without it. Purely local, JSON-
/// persisted (mirrors Mac's own local JSON file, just under
/// <c>%LocalAppData%\Mira\memory.json</c> instead of Application Support),
/// no server involvement at all — matching the confirmed absence of any
/// Supabase table for this feature.
/// </summary>
public sealed class MemoryStore
{
    public static MemoryStore Shared { get; } = new();

    private const string FileName = "memory.json";
    private const double ReinforceBoost = 0.08;
    private const double DailyDecayRate = 0.01;
    private const double DecayFloor = 0.10;
    private const double PromptBlockMinConfidence = 0.5;
    private const int PromptBlockMaxItems = 12;

    private readonly List<Memory> _memories = new();
    private readonly object _gate = new();

    public event Action? Changed;

    private MemoryStore()
    {
        Load();
        ApplyDecay(DateTimeOffset.UtcNow);
    }

    public IReadOnlyList<Memory> Memories { get { lock (_gate) return _memories.ToList(); } }

    /// <summary>Upsert a memory. If a matching key already exists, updates the value and reinforces confidence rather than overwriting it outright — mirrors <c>MemoryStore.upsert(key:value:...)</c>.</summary>
    public Memory Upsert(string key, string value, MemoryCategory category = MemoryCategory.Fact,
        MemorySource source = MemorySource.Explicit, double confidence = 0.95, string? notes = null)
    {
        var now = DateTimeOffset.UtcNow;
        var normKey = key.Trim().ToLowerInvariant();
        Memory result;
        lock (_gate)
        {
            var existing = _memories.FirstOrDefault(m => m.Key.ToLowerInvariant() == normKey);
            if (existing is not null)
            {
                existing.Value = value;
                existing.Notes = notes ?? existing.Notes;
                existing.UpdatedAt = now;
                existing.AccessCount++;
                existing.Confidence = ComputeReinforcedConfidence(existing.Confidence, confidence);
                result = existing;
            }
            else
            {
                result = new Memory
                {
                    Id = Guid.NewGuid(),
                    Key = key,
                    Value = value,
                    Category = category,
                    Source = source,
                    Confidence = confidence,
                    Notes = notes,
                    CreatedAt = now,
                    UpdatedAt = now,
                    AccessCount = 1,
                };
                _memories.Add(result);
            }
        }
        Persist();
        Changed?.Invoke();
        return result;
    }

    /// <summary>Fuzzy search by key or value substring, highest confidence first — mirrors <c>recall(query:)</c>.</summary>
    public IReadOnlyList<Memory> Recall(string query)
    {
        var q = query.ToLowerInvariant();
        lock (_gate)
        {
            return _memories
                .Where(m => m.Key.ToLowerInvariant().Contains(q) || m.Value.ToLowerInvariant().Contains(q))
                .OrderByDescending(m => m.Confidence)
                .ToList();
        }
    }

    public Memory? MemoryForKey(string key)
    {
        lock (_gate) return _memories.FirstOrDefault(m => string.Equals(m.Key, key, StringComparison.OrdinalIgnoreCase));
    }

    public void Delete(Guid id)
    {
        lock (_gate) _memories.RemoveAll(m => m.Id == id);
        Persist();
        Changed?.Invoke();
    }

    public void Delete(string key)
    {
        lock (_gate) _memories.RemoveAll(m => string.Equals(m.Key, key, StringComparison.OrdinalIgnoreCase));
        Persist();
        Changed?.Invoke();
    }

    public void Clear()
    {
        lock (_gate) _memories.Clear();
        try { File.Delete(LocalAppData.PathFor(FileName)); } catch { /* best-effort */ }
        Changed?.Invoke();
    }

    /// <summary>Bumps confidence when a memory is confirmed or referenced — mirrors <c>reinforce(key:)</c>.</summary>
    public void Reinforce(string key)
    {
        lock (_gate)
        {
            var existing = _memories.FirstOrDefault(m => string.Equals(m.Key, key, StringComparison.OrdinalIgnoreCase));
            if (existing is null) return;
            existing.Confidence = Math.Min(1.0, existing.Confidence + ReinforceBoost);
            existing.AccessCount++;
            existing.UpdatedAt = DateTimeOffset.UtcNow;
        }
        Persist();
        Changed?.Invoke();
    }

    /// <summary>Applies daily decay to every memory — mirrors <c>applyDecay()</c>, called once per launch (see constructor).</summary>
    public void ApplyDecay(DateTimeOffset now)
    {
        var changed = false;
        lock (_gate)
        {
            foreach (var m in _memories)
            {
                var days = (now - m.UpdatedAt).TotalDays;
                var decayed = ComputeDecayedConfidence(m.Confidence, days);
                if (Math.Abs(decayed - m.Confidence) > 0.0001)
                {
                    m.Confidence = decayed;
                    changed = true;
                }
            }
        }
        if (changed) Persist();
    }

    /// <summary>The top memories formatted for splicing into the chat system prompt — mirrors <c>buildPromptBlock()</c>, including its ≥0.5-confidence floor so uncertain guesses never get injected as fact.</summary>
    public string BuildPromptBlock()
    {
        List<Memory> relevant;
        lock (_gate)
        {
            relevant = _memories
                .Where(m => m.Confidence >= PromptBlockMinConfidence)
                .OrderByDescending(m => m.Confidence)
                .Take(PromptBlockMaxItems)
                .ToList();
        }
        return FormatPromptBlock(relevant);
    }

    /// <summary>Pure — mirrors <c>upsert</c>'s reinforcement math: <c>min(1.0, max(proposed, existing + 0.08))</c>.</summary>
    public static double ComputeReinforcedConfidence(double existingConfidence, double proposedConfidence) =>
        Math.Min(1.0, Math.Max(proposedConfidence, existingConfidence + ReinforceBoost));

    /// <summary>Pure — mirrors <c>applyDecay</c>'s per-memory math: −0.01/day, floor 0.10.</summary>
    public static double ComputeDecayedConfidence(double confidence, double daysSinceUpdate)
    {
        var decay = daysSinceUpdate * DailyDecayRate;
        return decay > 0.001 ? Math.Max(DecayFloor, confidence - decay) : confidence;
    }

    /// <summary>Pure — mirrors <c>buildPromptBlock</c>'s text formatting, including the tier-based qualifier suffix.</summary>
    public static string FormatPromptBlock(IReadOnlyList<Memory> relevant)
    {
        if (relevant.Count == 0) return "";
        var lines = new List<string> { "[What I know about you]" };
        foreach (var m in relevant)
        {
            var qualifier = m.ConfidenceTier switch
            {
                MemoryConfidenceTier.High => "",
                MemoryConfidenceTier.Medium => " (probably)",
                _ => " (uncertain)",
            };
            lines.Add($"{m.Key}: {m.Value}{qualifier}");
        }
        return string.Join("\n", lines);
    }

    private void Persist()
    {
        List<Memory> snapshot;
        lock (_gate) snapshot = _memories.ToList();
        try { File.WriteAllText(LocalAppData.PathFor(FileName), JsonConvert.SerializeObject(snapshot)); }
        catch { /* best-effort persistence */ }
    }

    private void Load()
    {
        try
        {
            var path = LocalAppData.PathFor(FileName);
            if (!File.Exists(path)) return;
            var list = JsonConvert.DeserializeObject<List<Memory>>(File.ReadAllText(path));
            if (list is not null) _memories.AddRange(list);
        }
        catch
        {
            // Corrupt/missing file -- start fresh rather than throwing on construction.
        }
    }
}
