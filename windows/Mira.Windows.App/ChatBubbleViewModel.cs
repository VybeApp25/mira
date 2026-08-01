using System.ComponentModel;
using System.Runtime.CompilerServices;
using Mira.Windows.Core.Chat;

namespace Mira.Windows.App;

/// <summary>One chat bubble. <see cref="Text"/> is mutable and raises <see cref="PropertyChanged"/> so a streaming assistant reply can update in place token-by-token.</summary>
public sealed class ChatBubbleViewModel : INotifyPropertyChanged
{
    private string _text;

    public ChatRole Role { get; }
    public bool IsUser => Role == ChatRole.User;

    public string Text
    {
        get => _text;
        set { _text = value; OnPropertyChanged(); }
    }

    public ChatBubbleViewModel(ChatRole role, string text)
    {
        Role = role;
        _text = text;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
