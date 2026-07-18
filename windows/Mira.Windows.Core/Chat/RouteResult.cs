using Mira.Windows.Core.Routing;

namespace Mira.Windows.Core.Chat;

public enum RouteResultKind { Reply, Clarify, Confirm, NotAvailable }

/// <summary>Simplified result type for <see cref="RouterHandler"/> — the Windows equivalent of macOS's <c>RouteResult</c> enum (Mira/Services/RouterService.swift).</summary>
public sealed record RouteResult(RouteResultKind Kind, string Text, MiraRoute Route);
