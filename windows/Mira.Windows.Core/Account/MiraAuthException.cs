namespace Mira.Windows.Core.Account;

/// <summary>Mirrors macOS's <c>MiraAuthError</c> (Mira/Services/AccountService.swift).</summary>
public sealed class MiraAuthException : Exception
{
    public MiraAuthException(string message) : base(message) { }

    public static MiraAuthException DeviceAlreadyRegistered() => new(
        "A free account already exists on this PC. Sign in to that account, or upgrade to " +
        "Pro to use Mira on multiple devices.");
}
