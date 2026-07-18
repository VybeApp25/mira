using System.Windows;
using System.Windows.Forms;
using Mira.Windows.Core.Account;
using Application = System.Windows.Application;

namespace Mira.Windows.App;

/// <summary>
/// System tray presence for the Windows client — the closest equivalent to how the
/// macOS app runs as an accessory/menu-bar-driven process (<c>LSUIElement</c>,
/// confirmed false in Mira/Info.plist, but the app is still built around
/// <c>StatusBarController.swift</c> + the always-present notch/island rather than
/// a conventional taskbar window). This is deliberately just a tray icon with a
/// context menu for this milestone — the notch/island UI itself is out of scope
/// (see docs/windows/IMPLEMENTATION_PLAN.md Phase 6: it has no backend dependency
/// and is sequenced after the plumbing here is proven, not before).
///
/// Uses <see cref="NotifyIcon"/> (System.Windows.Forms interop) rather than a
/// third-party WPF tray-icon package — WPF has no native tray-icon control, and
/// NotifyIcon is the standard, dependency-free way to get one from a WPF app
/// (enabled via <c>&lt;UseWindowsForms&gt;true&lt;/UseWindowsForms&gt;</c> in the
/// .csproj).
/// </summary>
public sealed class TrayIconManager : IDisposable
{
    private readonly NotifyIcon _icon;
    private readonly Action _openMainWindow;

    public TrayIconManager(Action openMainWindow)
    {
        _openMainWindow = openMainWindow;

        var menu = new ContextMenuStrip();
        menu.Items.Add("Open Mira", null, (_, _) => _openMainWindow());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Sign Out", null, (_, _) => AccountService.Shared.SignOut());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, (_, _) => Application.Current.Shutdown());

        _icon = new NotifyIcon
        {
            Icon = System.Drawing.SystemIcons.Application, // TODO: replace with a Mira-branded .ico once one exists
            Text = "Mira",
            Visible = true,
            ContextMenuStrip = menu,
        };
        _icon.DoubleClick += (_, _) => _openMainWindow();
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
