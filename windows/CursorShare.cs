using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows.Forms;

static class CursorShare
{
    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr mod, uint thread);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string? name);

    [StructLayout(LayoutKind.Sequential)]
    struct MSLLHOOKSTRUCT { public int x, y; public uint mouseData, flags, time; public IntPtr extra; }

    static HookProc? proc;
    static IntPtr hook;
    static volatile int px, py;
    static volatile bool dirty;
    static bool lastVisible;
    public static volatile StreamWriter? Writer;

    public static void Start()
    {
        proc = Callback;
        hook = SetWindowsHookEx(14, proc, GetModuleHandle(Process.GetCurrentProcess().MainModule?.ModuleName), 0);
        new Thread(Loop) { IsBackground = true }.Start();
    }

    static IntPtr Callback(int n, IntPtr w, IntPtr l)
    {
        if (n >= 0 && w.ToInt32() == 0x0200)
        {
            var d = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(l);
            if ((d.flags & 3) == 0) { px = d.x; py = d.y; dirty = true; }
        }
        return CallNextHookEx(hook, n, w, l);
    }

    static void Loop()
    {
        while (true)
        {
            Thread.Sleep(16);
            if (!dirty) continue;
            dirty = false;
            var w = Writer;
            if (w == null) continue;
            var scr = Screen.AllScreens.FirstOrDefault(s => !s.Primary);
            if (scr == null) continue;
            var b = scr.Bounds;
            bool inside = px >= b.X && px < b.X + b.Width && py >= b.Y && py < b.Y + b.Height;
            try
            {
                if (inside)
                {
                    double nx = (px - b.X) / (double)(b.Width - 1);
                    double ny = (py - b.Y) / (double)(b.Height - 1);
                    w.WriteLine(string.Format(CultureInfo.InvariantCulture, "C {0:F5} {1:F5}", nx, ny));
                    lastVisible = true;
                }
                else if (lastVisible)
                {
                    w.WriteLine("H");
                    lastVisible = false;
                }
            }
            catch { }
        }
    }
}