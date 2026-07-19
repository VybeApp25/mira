using System.Windows;
using Mira.Windows.App.Shell;

namespace Mira.Windows.App;

/// <summary>
/// Interaction logic for App.xaml. Starts as a tray-icon-only process (no window)
/// and opens <see cref="MainWindow"/> only on demand (from the tray) — see
/// App.xaml's ShutdownMode note.
/// </summary>
public partial class App : System.Windows.Application
{
    private TrayIconManager? _tray;
    private MainWindow? _mainWindow;
    private IslandWindow? _island;
    private AgentActivityWindow? _agentActivity;
    private OverlayWindow? _overlay;

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

        // The island is now the app's one always-shown surface at launch,
        // regardless of sign-in state -- it no longer waits for sign-in or
        // hides on sign-out the way it briefly did. Sign-in itself moved
        // into the island's own Settings tab, matching the Mac app (whose
        // notch is present for the whole session, with no separate
        // sign-in window at all). MainWindow still exists and is still
        // reachable from the tray as a manual fallback, but nothing about
        // launch or sign-in depends on it anymore.
        ShowIsland();

        // Inert until a computer-use run actually starts (which itself
        // requires being signed in), so there's no harm creating it
        // unconditionally at launch.
        _agentActivity = new AgentActivityWindow();

        // Same reasoning as _agentActivity -- inert until screen_guidance
        // actually locates a target, so no need to gate on sign-in.
        _overlay = new OverlayWindow();
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

    private void ShowIsland()
    {
        if (_island is null || !_island.IsLoaded)
        {
            _island = new IslandWindow();
            _island.Closed += (_, _) => _island = null;
        }
        _island.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _agentActivity?.Close();
        _overlay?.Close();
        _tray?.Dispose();
        base.OnExit(e);
    }
}
