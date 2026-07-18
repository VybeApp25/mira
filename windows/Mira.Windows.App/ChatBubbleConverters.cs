using System.Globalization;
using System.Windows.Data;
using System.Windows.Media;

namespace Mira.Windows.App;

// Fully-qualified WPF types throughout: <UseWindowsForms>true</UseWindowsForms>
// (needed for the tray icon, see TrayIconManager) pulls in System.Windows.Forms,
// which has its own HorizontalAlignment/Color/Brushes — ambiguous against the
// WPF (System.Windows/System.Windows.Media) types of the same name otherwise.

public sealed class BoolToAlignmentConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        => (value is true) ? System.Windows.HorizontalAlignment.Right : System.Windows.HorizontalAlignment.Left;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

public sealed class BoolToBubbleBrushConverter : IValueConverter
{
    private static readonly SolidColorBrush UserBrush = new(System.Windows.Media.Color.FromRgb(0x0A, 0x66, 0xC2));
    private static readonly SolidColorBrush AssistantBrush = new(System.Windows.Media.Color.FromRgb(0xE8, 0xE8, 0xEC));

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        => (value is true) ? UserBrush : AssistantBrush;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

public sealed class BoolToBubbleForegroundConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        => (value is true) ? System.Windows.Media.Brushes.White : System.Windows.Media.Brushes.Black;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
