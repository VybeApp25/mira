using System.Runtime.InteropServices;

namespace Mira.Windows.Core.Vision;

/// <summary>
/// The Windows equivalent of Mira/Services/ComputerUseService.swift's mouse/
/// keyboard half — synthetic input via Win32 <c>SendInput</c>, the direct
/// analog of the Swift original's <c>CGEvent</c> posted to <c>.cghidEventTap</c>
/// (both inject events at the OS/driver level, indistinguishable from real
/// hardware input to every app on the system).
///
/// Cursor positioning uses <c>SetCursorPos</c> (absolute pixel coordinates)
/// rather than <c>SendInput</c>'s own absolute-mouse-move mode, which requires
/// normalizing to a 0-65535 virtual-desktop coordinate space — <c>SetCursorPos</c>
/// takes real pixel coordinates directly, matching the coordinate space Claude's
/// computer-use tool already reports in, with no normalization step to get wrong.
/// <c>SendInput</c> is still used for the actual button-down/up and key events.
///
/// Typing uses <c>KEYEVENTF_UNICODE</c> (raw UTF-16 code units) rather than a
/// virtual-key mapping — the direct analog of the Swift original's
/// <c>keyboardSetUnicodeString</c>, and for the same reason: it types arbitrary
/// Unicode without depending on the active keyboard layout.
/// </summary>
public static class SyntheticInput
{
    // ---- Win32 interop ---------------------------------------------------------

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint Type;
        public InputUnion Data;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT Mouse;
        [FieldOffset(0)] public KEYBDINPUT Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int Dx, Dy;
        public uint MouseData, Flags, Time;
        public IntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort Vk, Scan;
        public uint Flags, Time;
        public IntPtr ExtraInfo;
    }

    private const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002, MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008, MOUSEEVENTF_RIGHTUP = 0x0010;
    private const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020, MOUSEEVENTF_MIDDLEUP = 0x0040;
    private const uint MOUSEEVENTF_WHEEL = 0x0800, MOUSEEVENTF_HWHEEL = 0x1000;
    private const uint KEYEVENTF_KEYUP = 0x0002, KEYEVENTF_UNICODE = 0x0004;
    private const int WHEEL_DELTA = 120;

    private static void Send(params INPUT[] inputs) => SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());

    private static INPUT MouseButtonInput(uint flags) => new()
    {
        Type = INPUT_MOUSE,
        Data = new InputUnion { Mouse = new MOUSEINPUT { Flags = flags } },
    };

    // ---- Mouse ------------------------------------------------------------------

    public static (int X, int Y) CursorPosition()
    {
        GetCursorPos(out var p);
        return (p.X, p.Y);
    }

    public static void MoveMouse(int x, int y) => SetCursorPos(x, y);

    public static void Click(int x, int y, string button = "left")
    {
        SetCursorPos(x, y);
        var (down, up) = button switch
        {
            "right" => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
            "middle" => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
            _ => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
        };
        Send(MouseButtonInput(down), MouseButtonInput(up));
    }

    public static void DoubleClick(int x, int y) => MultiClick(x, y, 2);

    public static void TripleClick(int x, int y) => MultiClick(x, y, 3);

    private static void MultiClick(int x, int y, int count)
    {
        SetCursorPos(x, y);
        for (var i = 0; i < count; i++)
            Send(MouseButtonInput(MOUSEEVENTF_LEFTDOWN), MouseButtonInput(MOUSEEVENTF_LEFTUP));
    }

    public static void Drag(int fromX, int fromY, int toX, int toY)
    {
        SetCursorPos(fromX, fromY);
        Send(MouseButtonInput(MOUSEEVENTF_LEFTDOWN));
        SetCursorPos(toX, toY);
        Send(MouseButtonInput(MOUSEEVENTF_LEFTUP));
    }

    public static void Scroll(int x, int y, string direction, int amount)
    {
        SetCursorPos(x, y);
        var (flags, delta) = direction switch
        {
            "up" => (MOUSEEVENTF_WHEEL, amount * WHEEL_DELTA),
            "down" => (MOUSEEVENTF_WHEEL, -amount * WHEEL_DELTA),
            "left" => (MOUSEEVENTF_HWHEEL, -amount * WHEEL_DELTA),
            "right" => (MOUSEEVENTF_HWHEEL, amount * WHEEL_DELTA),
            _ => (MOUSEEVENTF_WHEEL, 0),
        };
        Send(new INPUT { Type = INPUT_MOUSE, Data = new InputUnion { Mouse = new MOUSEINPUT { Flags = flags, MouseData = unchecked((uint)delta) } } });
    }

    /// <summary>Smoothly glides the cursor to (x, y) WITHOUT clicking — no button events, ever, matching the Swift original's "guide, don't operate" guarantee.</summary>
    public static async Task GlideMouseAsync(int toX, int toY, int steps = 14, double totalSeconds = 0.28, CancellationToken ct = default)
    {
        var (fromX, fromY) = CursorPosition();
        var dx = (double)(toX - fromX);
        var dy = (double)(toY - fromY);
        var n = Math.Max(1, steps);
        var perStepMs = (int)(totalSeconds / n * 1000);
        for (var i = 1; i <= n; i++)
        {
            var t = (double)i / n;
            var eased = 1 - Math.Pow(1 - t, 3); // ease-out
            MoveMouse(fromX + (int)(dx * eased), fromY + (int)(dy * eased));
            await Task.Delay(perStepMs, ct);
        }
    }

    // ---- Keyboard -----------------------------------------------------------------

    public static void Type(string text)
    {
        foreach (var ch in text)
        {
            Send(
                new INPUT { Type = INPUT_KEYBOARD, Data = new InputUnion { Keyboard = new KEYBDINPUT { Scan = ch, Flags = KEYEVENTF_UNICODE } } },
                new INPUT { Type = INPUT_KEYBOARD, Data = new InputUnion { Keyboard = new KEYBDINPUT { Scan = ch, Flags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP } } }
            );
        }
    }

    // Windows virtual-key codes — the analog of the Swift original's CGKeyCode
    // table, necessarily a different table (Mac ANSI scan codes vs. Windows VK_*).
    private static readonly Dictionary<string, ushort> KeyCodes = new()
    {
        ["a"] = 0x41, ["b"] = 0x42, ["c"] = 0x43, ["d"] = 0x44, ["e"] = 0x45, ["f"] = 0x46, ["g"] = 0x47,
        ["h"] = 0x48, ["i"] = 0x49, ["j"] = 0x4A, ["k"] = 0x4B, ["l"] = 0x4C, ["m"] = 0x4D, ["n"] = 0x4E,
        ["o"] = 0x4F, ["p"] = 0x50, ["q"] = 0x51, ["r"] = 0x52, ["s"] = 0x53, ["t"] = 0x54, ["u"] = 0x55,
        ["v"] = 0x56, ["w"] = 0x57, ["x"] = 0x58, ["y"] = 0x59, ["z"] = 0x5A,
        ["0"] = 0x30, ["1"] = 0x31, ["2"] = 0x32, ["3"] = 0x33, ["4"] = 0x34,
        ["5"] = 0x35, ["6"] = 0x36, ["7"] = 0x37, ["8"] = 0x38, ["9"] = 0x39,
        ["return"] = 0x0D, ["enter"] = 0x0D, ["tab"] = 0x09, ["space"] = 0x20,
        ["delete"] = 0x2E, ["backspace"] = 0x08, ["escape"] = 0x1B, ["esc"] = 0x1B,
        ["forwarddelete"] = 0x2E, ["home"] = 0x24, ["end"] = 0x23,
        ["pageup"] = 0x21, ["pagedown"] = 0x22,
        ["up"] = 0x26, ["down"] = 0x28, ["left"] = 0x25, ["right"] = 0x27,
        ["f1"] = 0x70, ["f2"] = 0x71, ["f3"] = 0x72, ["f4"] = 0x73, ["f5"] = 0x74,
        ["f6"] = 0x75, ["f7"] = 0x76, ["f8"] = 0x77, ["f9"] = 0x78, ["f10"] = 0x79, ["f11"] = 0x7A, ["f12"] = 0x7B,
    };

    private const ushort VK_CONTROL = 0x11, VK_MENU = 0x12, VK_SHIFT = 0x10, VK_LWIN = 0x5B;
    private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;

    /// <summary>Presses a combo like "ctrl+c", "shift+return", "escape" — modifier names accept ctrl/control, cmd/command/super/win (mapped to the Windows key), opt/option/alt, shift.</summary>
    public static void Key(string combination)
    {
        var parts = combination.ToLowerInvariant().Split('+').Select(p => p.Trim()).ToList();
        var keyName = parts[^1];
        var modifierNames = parts.Take(parts.Count - 1);

        var modifierVks = new List<ushort>();
        foreach (var mod in modifierNames)
        {
            var vk = mod switch
            {
                "ctrl" or "control" => VK_CONTROL,
                "cmd" or "command" or "super" or "win" or "windows" => VK_LWIN,
                "opt" or "option" or "alt" => VK_MENU,
                "shift" => VK_SHIFT,
                _ => (ushort)0,
            };
            if (vk != 0) modifierVks.Add(vk);
        }

        var keyVk = KeyCodes.GetValueOrDefault(keyName, (ushort)0);

        foreach (var vk in modifierVks) Send(KeyInput(vk, down: true));
        Send(KeyInput(keyVk, down: true));
        Send(KeyInput(keyVk, down: false));
        foreach (var vk in Enumerable.Reverse(modifierVks)) Send(KeyInput(vk, down: false));
    }

    private static INPUT KeyInput(ushort vk, bool down) => new()
    {
        Type = INPUT_KEYBOARD,
        Data = new InputUnion { Keyboard = new KEYBDINPUT { Vk = vk, Flags = down ? 0u : KEYEVENTF_KEYUP } },
    };
}
