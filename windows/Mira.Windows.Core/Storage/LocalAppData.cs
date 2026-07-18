namespace Mira.Windows.Core.Storage;

/// <summary>
/// The Windows equivalent of macOS's <c>~/Library/Application Support/Mira/</c>
/// convention (confirmed throughout the macOS codebase — e.g. MemoryStore.swift,
/// ProjectEngine.swift, AgentJobStore.swift, OutputStore.swift all resolve
/// <c>FileManager.default.urls(for: .applicationSupportDirectory, ...)</c> then
/// append "Mira"). On Windows the per-user, non-roaming equivalent is
/// <c>%LOCALAPPDATA%</c> (roaming <c>%APPDATA%</c> is the closer literal analog of
/// "Application Support" for some purposes, but local storage that shouldn't
/// follow a roaming profile across machines — sessions, device fingerprints,
/// local JSON stores — belongs in LocalAppData; see
/// docs/windows/WINDOWS_ARCHITECTURE.md §2).
/// </summary>
public static class LocalAppData
{
    /// <summary>
    /// <c>%LOCALAPPDATA%\Mira</c>, created if it doesn't exist yet. Mirrors the
    /// macOS services' own "create the directory if needed, then return the file
    /// path" pattern exactly (e.g. MemoryStore.swift's <c>storeURL</c>).
    /// </summary>
    public static string MiraDirectory
    {
        get
        {
            var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var dir = Path.Combine(baseDir, "Mira");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    public static string PathFor(string fileName) => Path.Combine(MiraDirectory, fileName);
}
