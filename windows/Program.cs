using System.Diagnostics;
using System.Drawing;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Windows.Forms;

using var single = new Mutex(true, "MacDisplayHost.Single", out bool first);
if (!first) return;

Injector.SetProcessDPIAware();
Application.EnableVisualStyles();

int outIdx = args.Length > 0 ? int.Parse(args[0]) : 1;
string bitrate = args.Length > 1 ? args[1] : "8M";
string dir = AppContext.BaseDirectory;
string logPath = Path.Combine(Path.GetTempPath(), "MacDisplayHost.log");
Process? ff = null;

void Log(string m) { try { File.AppendAllText(logPath, $"{DateTime.Now:T} {m}\n"); } catch { } }

bool IsCable(IPAddress a)
{
    if (a.AddressFamily != AddressFamily.InterNetwork) return false;
    var b = a.GetAddressBytes();
    return (b[0] == 169 && b[1] == 254) || (b[0] == 192 && b[1] == 168 && b[2] == 50);
}

// 1) Beacon: tell the Mac "I'm here", only on the cable network
new Thread(() =>
{
    var msg = Encoding.ASCII.GetBytes("MACDISPLAY1");
    string lastErr = "";
    while (true)
    {
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                {
                    try
                    {
                        if (ua.IPv4Mask == null || !IsCable(ua.Address)) continue;
                        if (ua.DuplicateAddressDetectionState != DuplicateAddressDetectionState.Preferred) continue;
                        var ip = ua.Address.GetAddressBytes();
                        var mk = ua.IPv4Mask.GetAddressBytes();
                        var bc = new IPAddress(ip.Select((x, i) => (byte)(x | ~mk[i])).ToArray());
                        using var udp = new UdpClient(new IPEndPoint(ua.Address, 0)) { EnableBroadcast = true };
                        udp.Send(msg, msg.Length, new IPEndPoint(bc, 5002));
                    }
                    catch (Exception e)
                    {
                        if (e.Message != lastErr) { lastErr = e.Message; Log("beacon (" + ni.Name + "): " + e.Message); }
                    }
                }
            }
        }
        catch (Exception e)
        {
            if (e.Message != lastErr) { lastErr = e.Message; Log("beacon: " + e.Message); }
        }
        Thread.Sleep(1000);
    }
}) { IsBackground = true }.Start();

// 2) Input server: mouse/keyboard from the Mac (cable network only)
new Thread(() =>
{
    var listener = new TcpListener(IPAddress.Any, 5001);
    listener.Start();
    while (true)
    {
        try
        {
            using var client = listener.AcceptTcpClient();
            var remote = ((IPEndPoint)client.Client.RemoteEndPoint!).Address;
            if (!IsCable(remote)) { Log("rejected input from " + remote); continue; }
            var t = Screen.AllScreens.FirstOrDefault(s => !s.Primary);
            if (t == null) { Log("no second screen"); continue; }
            client.NoDelay = true;
            Injector.Init(t.Bounds);
            Log("input connected from " + remote);
            using var reader = new StreamReader(client.GetStream());
            string? line;
            var writer = new StreamWriter(client.GetStream()) { AutoFlush = true, NewLine = "\n" }; CursorShare.Writer = writer; try { while ((line = reader.ReadLine()) != null) Injector.Handle(line); } finally { CursorShare.Writer = null; }
        }
        catch { }
    }
}) { IsBackground = true }.Start();

// 3) Sender: ffmpeg, restarted whenever it exits
new Thread(() =>
{
    string exe = Path.Combine(dir, "ffmpeg.exe");
    if (!File.Exists(exe)) exe = "ffmpeg";
    while (true)
    {
        try
        {
            try { if (new FileInfo(logPath).Length > 500_000) File.Delete(logPath); } catch { }
            var psi = new ProcessStartInfo(exe)
            {
                Arguments = $"-hide_banner -loglevel error -f lavfi -i \"ddagrab=output_idx={outIdx}:framerate=30:draw_mouse=0,hwdownload,format=bgra,format=nv12\" -r 30 -fps_mode cfr -c:v h264_qsv -preset veryfast -bf 0 -g 30 -async_depth 1 -b:v {bitrate} -flush_packets 1 -f h264 \"tcp://0.0.0.0:5000?listen=1\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardError = true
            };
            ff = Process.Start(psi);
            ff!.ErrorDataReceived += (s, e) => { if (e.Data != null) Log("ffmpeg: " + e.Data); };
            ff.BeginErrorReadLine();
            ff.WaitForExit();
        }
        catch (Exception e) { Log("sender: " + e.Message); }
        Thread.Sleep(1500);
    }
}) { IsBackground = true }.Start();

// Tray icon
var tray = new NotifyIcon { Icon = SystemIcons.Application, Text = "Mac Display Host", Visible = true };
var menu = new ContextMenuStrip();
menu.Items.Add("Mac Display Host (running)").Enabled = false;
menu.Items.Add("Open log", null, (s, e) => Process.Start(new ProcessStartInfo("notepad.exe", logPath) { UseShellExecute = true }));
menu.Items.Add("Quit", null, (s, e) =>
{
    try { ff?.Kill(true); } catch { }
    tray.Visible = false;
    Environment.Exit(0);
});
tray.ContextMenuStrip = menu;
CursorShare.Start(); Application.Run();

