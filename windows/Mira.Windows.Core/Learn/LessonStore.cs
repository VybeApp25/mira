using Mira.Windows.Core.Storage;
using Newtonsoft.Json;

namespace Mira.Windows.Core.Learn;

/// <summary>
/// The Windows equivalent of Mira/Services/SkillCatalog.swift -- combined with
/// the role Mac splits into a separate store, since Learn lessons need no
/// active/inactive toggle the way prompt-injection skills do (see
/// <see cref="Skills.SkillStore"/>, an unrelated, already-ported feature this
/// one's name could otherwise be confused with). One JSON file per user
/// lesson under <c>%LocalAppData%\Mira\Lessons\</c> (a deliberate
/// simplification of Mac's <c>SKILL.md</c> + <c>steps.json</c> two-file
/// progressive-disclosure format -- Windows has no equivalent size pressure
/// to defer parsing a lesson's steps, so one file is simpler and equally honest).
/// </summary>
public sealed class LessonStore
{
    public static LessonStore Shared { get; } = new();

    private readonly List<Lesson> _userLessons = new();
    private readonly object _gate = new();

    public event Action? Changed;

    private LessonStore() => _userLessons.AddRange(LoadUserLessons());

    public static string LessonsDirectory => Path.Combine(LocalAppData.MiraDirectory, "Lessons");

    /// <summary>Built-ins first, then user lessons -- matches the Mac tab's own display order.</summary>
    public IReadOnlyList<Lesson> All { get { lock (_gate) return LessonCatalog.Builtins.Concat(_userLessons).ToList(); } }

    public Lesson? Find(string id) => All.FirstOrDefault(l => l.Id == id);

    /// <summary>
    /// Validates a lesson has at least one step with a real instruction before
    /// accepting it -- mirrors <c>SkillCatalog</c>'s "flag invalid rather than
    /// silently drop" principle. Extracted as a pure static method so it's
    /// directly unit-testable.
    /// </summary>
    public static (bool Valid, string? Reason) Validate(Lesson lesson)
    {
        if (lesson.Steps.Count == 0) return (false, "Lesson has no steps.");
        if (lesson.Steps.Any(s => string.IsNullOrWhiteSpace(s.Instruction))) return (false, "A step is missing its instruction.");
        if (string.IsNullOrWhiteSpace(lesson.Title)) return (false, "Lesson has no title.");
        return (true, null);
    }

    public (bool Success, string? Error) Add(Lesson lesson)
    {
        var (valid, reason) = Validate(lesson);
        if (!valid) return (false, reason);

        lock (_gate) _userLessons.Add(lesson);
        Persist(lesson);
        Changed?.Invoke();
        return (true, null);
    }

    public void Remove(string id)
    {
        lock (_gate) _userLessons.RemoveAll(l => l.Id == id);
        try { File.Delete(Path.Combine(LessonsDirectory, $"{id}.json")); } catch { /* best-effort */ }
        Changed?.Invoke();
    }

    private static void Persist(Lesson lesson)
    {
        try
        {
            Directory.CreateDirectory(LessonsDirectory);
            File.WriteAllText(Path.Combine(LessonsDirectory, $"{lesson.Id}.json"), JsonConvert.SerializeObject(lesson));
        }
        catch
        {
            // Best-effort persistence -- a failed write shouldn't crash the create flow; the lesson stays usable for this session in memory.
        }
    }

    private static List<Lesson> LoadUserLessons()
    {
        var result = new List<Lesson>();
        if (!Directory.Exists(LessonsDirectory)) return result;

        foreach (var file in Directory.GetFiles(LessonsDirectory, "*.json"))
        {
            try
            {
                var lesson = JsonConvert.DeserializeObject<Lesson>(File.ReadAllText(file));
                if (lesson is not null && Validate(lesson).Valid) result.Add(lesson);
            }
            catch
            {
                // Corrupt lesson file -- skip it rather than fail the whole catalog load.
            }
        }
        return result;
    }
}
