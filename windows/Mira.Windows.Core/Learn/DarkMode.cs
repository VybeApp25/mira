using Microsoft.Win32;

namespace Mira.Windows.Core.Learn;

/// <summary>
/// The Windows equivalent of checking <c>UserDefaults</c>("AppleInterfaceStyle")
/// for <see cref="LessonCheckKind.DarkModeEnabled"/> steps -- reads the same
/// registry value Windows Settings itself writes when the user toggles
/// light/dark mode under Personalization &gt; Colors.
/// </summary>
public static class DarkMode
{
    private const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(KeyPath);
            return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
        }
        catch
        {
            return false;
        }
    }
}
