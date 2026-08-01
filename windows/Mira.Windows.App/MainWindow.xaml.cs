using System.Windows;
using Mira.Windows.Core.Account;
using Mira.Windows.Core.Entitlements;
using Mira.Windows.Core.Vision;

namespace Mira.Windows.App;

/// <summary>
/// The bare sign-in/status window for this milestone — deliberately NOT the
/// notch/island shell (see docs/windows/IMPLEMENTATION_PLAN.md's phase sequence:
/// the shell UI is sequenced after auth/entitlements are proven, not before,
/// since it has zero backend dependency and can be designed on Windows-native
/// terms without blocking on it here).
/// </summary>
public partial class MainWindow : Window
{
    private bool _isSignUpMode;

    public MainWindow()
    {
        InitializeComponent();

        AccountService.Shared.StateChanged += OnAuthStateChanged;
        EntitlementService.Shared.PlanChanged += OnPlanChanged;
        Closed += (_, _) =>
        {
            AccountService.Shared.StateChanged -= OnAuthStateChanged;
            EntitlementService.Shared.PlanChanged -= OnPlanChanged;
        };

        RenderForState(AccountService.Shared.State);
        AutonomyCheckBox.IsChecked = AutonomySettings.ComputerUseEnabled;
    }

    private void OnAuthStateChanged(AuthState state) => Dispatcher.Invoke(() => RenderForState(state));

    private void OnPlanChanged(Mira.Contracts.ProfileRow.ProfilePlan plan) => Dispatcher.Invoke(UpdatePlanText);

    private void RenderForState(AuthState state)
    {
        switch (state)
        {
            case AuthState.SignedIn:
                SignedOutPanel.Visibility = Visibility.Collapsed;
                SignedInPanel.Visibility = Visibility.Visible;
                var user = AccountService.Shared.CurrentUser;
                SignedInAsText.Text = $"Signed in as {user?.Email ?? user?.DisplayName ?? "(unknown)"}";
                UpdatePlanText();
                break;

            case AuthState.SignedOut:
                SignedOutPanel.Visibility = Visibility.Visible;
                SignedInPanel.Visibility = Visibility.Collapsed;
                PrimaryActionButton.IsEnabled = true;
                break;

            case AuthState.Loading:
                PrimaryActionButton.IsEnabled = false;
                break;
        }
    }

    private void UpdatePlanText() => PlanText.Text = $"Plan: {EntitlementService.Shared.Plan.DisplayName()}";

    private async void PrimaryActionButton_Click(object sender, RoutedEventArgs e)
    {
        ErrorText.Text = "";
        var email = EmailBox.Text.Trim();
        var password = PasswordBox.Password;

        if (string.IsNullOrEmpty(email) || string.IsNullOrEmpty(password))
        {
            ErrorText.Text = "Enter an email and password.";
            return;
        }

        try
        {
            if (_isSignUpMode)
            {
                var name = DisplayNameBox.Text.Trim();
                await AccountService.Shared.SignUpAsync(email, password, name);
                if (!AccountService.Shared.IsSignedIn)
                {
                    // SignUpAsync returned with no session and no exception = pending
                    // email confirmation — not an error, mirrors AccountService.swift.
                    ErrorText.Foreground = System.Windows.Media.Brushes.DarkGreen;
                    ErrorText.Text = "Check your email to confirm your account, then sign in.";
                    _isSignUpMode = false;
                    ApplyModeToUi();
                }
            }
            else
            {
                await AccountService.Shared.SignInAsync(email, password);
            }
        }
        catch (Exception ex)
        {
            ErrorText.Foreground = System.Windows.Media.Brushes.Red;
            ErrorText.Text = ex.Message;
        }
    }

    private void ToggleModeButton_Click(object sender, RoutedEventArgs e)
    {
        _isSignUpMode = !_isSignUpMode;
        ApplyModeToUi();
    }

    private void ApplyModeToUi()
    {
        ModeLabel.Text = _isSignUpMode ? "Create account" : "Sign in";
        PrimaryActionButton.Content = _isSignUpMode ? "Create Account" : "Sign In";
        ToggleModeButton.Content = _isSignUpMode ? "Already have an account? Sign in" : "Need an account? Create one";
        DisplayNamePanel.Visibility = _isSignUpMode ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void RefreshPlanButton_Click(object sender, RoutedEventArgs e)
    {
        await EntitlementService.Shared.FetchAndApplyPlanAsync();
    }

    private void SignOutButton_Click(object sender, RoutedEventArgs e)
    {
        AccountService.Shared.SignOut();
    }

    private void OpenChatButton_Click(object sender, RoutedEventArgs e)
    {
        new ChatWindow().Show();
    }

    private void AutonomyCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        AutonomySettings.ComputerUseEnabled = AutonomyCheckBox.IsChecked == true;
    }
}
