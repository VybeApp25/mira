using System.Windows;

namespace Mira.Windows.App;

/// <summary>
/// Interaction logic for App.xaml. Starts as a tray-icon-only process (no window)
/// and opens <see cref="MainWindow"/> on demand — see App.xaml's ShutdownMode note.
/// </summary>
public partial class App : System.Windows.Application
{
    private TrayIconManager? _tray;
    private MainWindow? _mainWindow;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _tray = new TrayIconManager(ShowMainWindow);
        ShowMainWindow(); // first run: surface the sign-in UI immediately rather than
                          // leaving a brand-new user staring at nothing but a tray icon
    }

    private void ShowMainWindow()
    {
        if (_mainWindow is null || !_mainWindow.IsLoaded)
        {
            _mainWindow = new MainWindow();
            _mainWindow.Closed += (_, _) => _mainWindow = null;
        }
        _mainWindow.Show();
        _mainWindow.Activate();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        base.OnExit(e);
    }
}
