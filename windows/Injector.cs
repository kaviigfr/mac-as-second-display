using System.Drawing;
using System.Globalization;
using System.Runtime.InteropServices;

static class Injector
{
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int n);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);

    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public UNION u; }

    static Rectangle bounds;
    static int vx, vy, vw, vh;

    public static void Init(Rectangle b)
    {
        bounds = b;
        vx = GetSystemMetrics(76); vy = GetSystemMetrics(77);
        vw = GetSystemMetrics(78); vh = GetSystemMetrics(79);
    }

    public static void Handle(string line)
    {
        try
        {
            var p = line.Split(' ');
            switch (p[0])
            {
                case "M": Move(D(p[1]), D(p[2])); break;
                case "D": Button(int.Parse(p[1]), true); break;
                case "U": Button(int.Parse(p[1]), false); break;
                case "W": Wheel(D(p[1]), D(p[2])); break;
                case "K": Key(int.Parse(p[1]), p[2] == "1"); break;
            }
        }
        catch { }
    }

    static double D(string s) => double.Parse(s, CultureInfo.InvariantCulture);

    static void Mouse(int dx, int dy, uint data, uint flags)
    {
        var i = new INPUT { type = 0 };
        i.u.mi = new MOUSEINPUT { dx = dx, dy = dy, mouseData = data, dwFlags = flags };
        SendInput(1, new[] { i }, Marshal.SizeOf<INPUT>());
    }

    static void Move(double nx, double ny)
    {
        nx = Math.Clamp(nx, 0, 1); ny = Math.Clamp(ny, 0, 1);
        double px = bounds.X + nx * (bounds.Width - 1);
        double py = bounds.Y + ny * (bounds.Height - 1);
        int ax = (int)((px - vx) * 65535.0 / (vw - 1));
        int ay = (int)((py - vy) * 65535.0 / (vh - 1));
        Mouse(ax, ay, 0, 0x0001 | 0x8000 | 0x4000); // move | absolute | virtual desktop
    }

    static void Button(int b, bool down)
    {
        uint f = b switch
        {
            0 => down ? 0x0002u : 0x0004u,
            1 => down ? 0x0008u : 0x0010u,
            _ => down ? 0x0020u : 0x0040u
        };
        Mouse(0, 0, 0, f);
    }

    static void Wheel(double dx, double dy)
    {
        int y = (int)Math.Round(dy), x = (int)Math.Round(dx);
        if (y != 0) Mouse(0, 0, unchecked((uint)y), 0x0800);
        if (x != 0) Mouse(0, 0, unchecked((uint)x), 0x1000);
    }

    static void Key(int mac, bool down)
    {
        if (!Map.TryGetValue(mac, out int vk)) return;
        uint flags = down ? 0u : 2u;
        if ((vk >= 0x21 && vk <= 0x28) || vk == 0x2D || vk == 0x2E || vk == 0xA3 || vk == 0xA5) flags |= 1;
        var i = new INPUT { type = 1 };
        i.u.ki = new KEYBDINPUT { wVk = (ushort)vk, wScan = (ushort)MapVirtualKey((uint)vk, 0), dwFlags = flags };
        SendInput(1, new[] { i }, Marshal.SizeOf<INPUT>());
    }

    // Mac key code -> Windows virtual key. Cmd -> Ctrl, Option -> Alt.
    static readonly Dictionary<int, int> Map = new()
    {
        {0x00,0x41},{0x0B,0x42},{0x08,0x43},{0x02,0x44},{0x0E,0x45},{0x03,0x46},{0x05,0x47},{0x04,0x48},
        {0x22,0x49},{0x26,0x4A},{0x28,0x4B},{0x25,0x4C},{0x2E,0x4D},{0x2D,0x4E},{0x1F,0x4F},{0x23,0x50},
        {0x0C,0x51},{0x0F,0x52},{0x01,0x53},{0x11,0x54},{0x20,0x55},{0x09,0x56},{0x0D,0x57},{0x07,0x58},
        {0x10,0x59},{0x06,0x5A},
        {0x1D,0x30},{0x12,0x31},{0x13,0x32},{0x14,0x33},{0x15,0x34},{0x17,0x35},{0x16,0x36},{0x1A,0x37},
        {0x1C,0x38},{0x19,0x39},
        {0x18,0xBB},{0x1B,0xBD},{0x1E,0xDD},{0x21,0xDB},{0x27,0xDE},{0x29,0xBA},{0x2A,0xDC},{0x2B,0xBC},
        {0x2C,0xBF},{0x2F,0xBE},{0x32,0xC0},
        {0x24,0x0D},{0x30,0x09},{0x31,0x20},{0x33,0x08},{0x35,0x1B},{0x75,0x2E},
        {0x73,0x24},{0x77,0x23},{0x74,0x21},{0x79,0x22},{0x7B,0x25},{0x7C,0x27},{0x7D,0x28},{0x7E,0x26},
        {0x37,0xA2},{0x36,0xA3},{0x38,0xA0},{0x3C,0xA1},{0x3A,0xA4},{0x3D,0xA5},{0x39,0x14},
        {0x7A,0x70},{0x78,0x71},{0x63,0x72},{0x76,0x73},{0x60,0x74},{0x61,0x75},{0x62,0x76},{0x64,0x77},
        {0x65,0x78},{0x6D,0x79},{0x67,0x7A},{0x6F,0x7B}
    };
}
