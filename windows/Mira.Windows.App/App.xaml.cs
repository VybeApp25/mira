using System.Windows;
using Mira.Windows.App.Shell;
using Mira.Windows.Core.Account;

namespace Mira.Windows.App;

/// <summary>
/// Interaction logic for App.xaml. Starts as a tray-icon-only process (no window)
/// and opens <see cref="MainWindow"/> on demand — see App.xaml's ShutdownMode note.
/// </summary>
public partial class App : System.Windows.Application
{
    private TrayIconManager? _tray;
    private MainWindow? _mainWindow;
    private IslandWindow? _island;

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

        _tray = new TrayIconManager(ShowMainWindow, ShowIsland);

        // The island is the Windows equivalent of the Mac app's always-present
        // notch shell (Phase 6) — it shows itself once signed in, same as
        // NotchManager.setup() runs for the whole session on macOS, rather
        // than needing to be opened like Chat/Voice do.
        AccountService.Shared.StateChanged += OnAuthStateChanged;
        if (AccountService.Shared.IsSignedIn) ShowIsland();

        ShowMainWindow(); // first run: surface the sign-in UI immediately rather than
                          // leaving a brand-new user staring at nothing but a tray icon
    }

    private void OnAuthStateChanged(AuthState state) => Dispatcher.Invoke(() =>
    {
        if (state == AuthState.SignedIn) ShowIsland();
        else if (state == AuthState.SignedOut) HideIsland();
    });

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

    private void ShowIsland()
    {
        if (_island is null || !_island.IsLoaded)
        {
            _island = new IslandWindow();
            _island.Closed += (_, _) => _island = null;
        }
        _island.Show();
    }

    private void HideIsland()
    {
        _island?.Close();
        _island = null;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        AccountService.Shared.StateChanged -= OnAuthStateChanged;
        _tray?.Dispose();
        base.OnExit(e);
    }
}
