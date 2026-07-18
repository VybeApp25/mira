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

        // Without this, any unhandled exception anywhere (UI thread or
        // background) silently kills the whole process with no dialog, no
        // log, nothing to go on -- exactly what made the voice PTT crash
        // (an STA/MTA COM apartment mismatch in WasapiCapture, fixed in
        // RealtimeVoiceService.BeginRecordingAsync) invisible until the user
        // reported it manually. Now it at least surfaces a message instead of
        // vanishing.
        DispatcherUnhandledException += (_, args) =>
        {
            System.Windows.MessageBox.Show($"Mira hit an unexpected error:\n\n{args.Exception.Message}",
                "Mira", MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception ex)
                System.Windows.MessageBox.Show($"Mira hit an unexpected error and needs to close:\n\n{ex.Message}",
                    "Mira", MessageBoxButton.OK, MessageBoxImage.Error);
        };

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
