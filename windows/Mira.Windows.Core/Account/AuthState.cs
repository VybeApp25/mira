namespace Mira.Windows.Core.Account;

/// <summary>Mirrors macOS's <c>AuthState</c> enum (Mira/Services/AccountService.swift).</summary>
public enum AuthState
{
    SignedOut,
    SignedIn,
    Loading,
}
