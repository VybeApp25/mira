namespace Mira.Windows.Core.Chat;

public enum ChatRole { User, Assistant }

public sealed class ChatMessage
{
    public required ChatRole Role { get; init; }
    public required string Content { get; init; }
    public DateTimeOffset Timestamp { get; init; } = DateTimeOffset.UtcNow;
}
