# Mac as Second Display

Use a MacBook screen as a real second monitor for a Windows laptop, over a direct Ethernet cable. No internet, no router, and no manual IP setup.

I built this because my Windows laptop has a 1366x768 screen and my MacBook Air M1 has a 2560x1600 one. Windows sees a virtual monitor, streams it to the Mac as hardware-encoded H.264, and the Mac sends mouse and keyboard input back.

## Features

- Plug in the cable and it connects by itself (link-local addresses plus UDP auto-discovery)
- Low-latency H.264: Intel QuickSync encode on Windows, VideoToolbox decode on the Mac
- Real second monitor: drag windows between screens, choose the resolution
- Mouse and keyboard from the Mac control the virtual monitor (Cmd acts as Ctrl, Option as Alt)
- The Windows cursor shows on the Mac only when you use the physical Windows mouse, and hides when you use the Mac mouse
- Auto-reconnect on both sides, and fullscreen with Ctrl+Cmd+F
- Windows tray app and a normal macOS `.app`

## How it works

```
 Windows laptop                                       MacBook
+-------------------------------+                +--------------------------+
| Virtual display (Virtual      |                | ScreenViewer.app         |
| Display Driver, 1920x1080)    |                |                          |
|   -> ffmpeg (ddagrab + QSV)   | -- TCP 5000 -> |  H.264 -> VideoToolbox   |
| MacDisplayHost (tray app)     | <- TCP 5001 -- |  mouse / keyboard        |
|   -> beacon "MACDISPLAY1"     | -- UDP 5002 -> |  auto-discovery          |
+-------------------------------+   Ethernet     +--------------------------+
```

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 5000 | TCP | Windows to Mac | Raw H.264 video stream |
| 5001 | TCP | both | Input events (Mac to Windows) and cursor position (Windows to Mac) |
| 5002 | UDP | Windows to Mac (broadcast) | Discovery beacon, payload `MACDISPLAY1` |

Input lines sent by the Mac: `M x y` (position, 0 to 1), `D b` / `U b` (button down/up), `W dx dy` (scroll), `K code down` (key). Lines sent by Windows: `C x y` (show the Windows cursor overlay at this position) and `H` (hide it).

## Requirements

**Windows**
- Windows 10 or 11
- .NET 8 SDK
- Intel graphics with QuickSync (the sender uses `h264_qsv`; NVIDIA or AMD would need a different ffmpeg encoder, which I haven't tested)
- A recent FFmpeg with the `ddagrab` source (tested with FFmpeg 8.0 from gyan.dev)
- [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)

**Mac**
- macOS 12 or newer, Apple Silicon (tested on a MacBook Air M1)
- Xcode Command Line Tools (`xcode-select --install`)
- A USB-C Ethernet adapter

**Hardware:** one Ethernet cable between the two machines (plus a USB Ethernet adapter on a laptop with no port).

## Windows setup

Do these once.

**1. Network.** Set the Ethernet adapter on both machines to automatic (Windows: Settings > Network > Ethernet > IP assignment > Automatic (DHCP). Mac: System Settings > Network > your USB Ethernet > Details > TCP/IP > Using DHCP). With no router, both sides give themselves a `169.254.x.x` address after up to a minute.

**2. Install the virtual display driver.** In an Administrator Windows PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
Invoke-WebRequest "https://raw.githubusercontent.com/VirtualDrivers/Virtual-Display-Driver/master/Community%20Scripts/silent-install.ps1" -OutFile "$HOME\silent-install.ps1"
& "$HOME\silent-install.ps1"
```

**3. Add the driver's settings file.** It turns on the driver's hardware cursor, which keeps the Windows cursor out of the video. In an Administrator PowerShell:

```powershell
New-Item -ItemType Directory -Path C:\VirtualDisplayDriver -Force
Invoke-WebRequest "https://raw.githubusercontent.com/VirtualDrivers/Virtual-Display-Driver/master/Virtual%20Display%20Driver%20(HDR)/vdd_settings.xml" -OutFile C:\VirtualDisplayDriver\vdd_settings.xml
```

Then reload the driver: Device Manager > Display adapters > right-click the virtual adapter > Disable device, then Enable device (or just restart).

**4. Extend the display.** Press `Win+P` and choose **Extend**. In Settings > System > Display, set the new monitor to **1920x1080** and drag it to the right of your main screen. Keep it on Extend, because the sender cannot capture the virtual monitor otherwise.

Optional: add 1920x1200 and 2560x1600 modes (Administrator PowerShell), then reload the driver:

```powershell
$f = 'C:\VirtualDisplayDriver\vdd_settings.xml'
$x = Get-Content $f -Raw
$add = '<resolution><width>1920</width><height>1200</height><refresh_rate>60</refresh_rate></resolution><resolution><width>2560</width><height>1600</height><refresh_rate>60</refresh_rate></resolution></resolutions>'
Set-Content $f ($x -replace '</resolutions>', $add)
```

**5. Build the host app.** From the `windows` folder:

```powershell
dotnet publish -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o $HOME\MacDisplayHost
```

**6. Add FFmpeg.** Install FFmpeg yourself (this repo does not include it), then copy it next to the app so the app can find it:

```powershell
Copy-Item (Get-Command ffmpeg).Source $HOME\MacDisplayHost\ffmpeg.exe
```

**7. Open the firewall for the cable network.** This allows ports 5000 and 5001 only from the cable network (`169.254.x.x`, plus `192.168.50.x` if you use static IPs), so nothing else can reach them. Run it once, in an Administrator PowerShell, on each Windows machine that runs the host app:

```powershell
New-NetFirewallRule -DisplayName "Mac Display" -Direction Inbound -Protocol TCP -LocalPort 5000,5001 -RemoteAddress 169.254.0.0/16,192.168.50.0/24 -Action Allow -Profile Any
```

To remove it later:

```powershell
Remove-NetFirewallRule -DisplayName "Mac Display"
```

**8. Run it.** There is no console window. Look for the tray icon (under the `^` arrow):

```powershell
& $HOME\MacDisplayHost\MacDisplayHost.exe
```

Optional: start it with Windows:

```powershell
$s=(New-Object -ComObject WScript.Shell).CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\MacDisplayHost.lnk"); $s.TargetPath="$HOME\MacDisplayHost\MacDisplayHost.exe"; $s.Save()
```

Right-click the tray icon for **Open log** and **Quit**. The log is at `%TEMP%\MacDisplayHost.log`.

## Mac setup

**1. Build and install the app.** From the `mac` folder:

```bash
bash build-app.sh
```

This compiles the viewer, builds `ScreenViewer.app`, signs it ad hoc, and installs it to `/Applications`.

**2. Create a shortcut.** Put a shortcut on the Desktop:

```bash
ln -sf /Applications/ScreenViewer.app ~/Desktop/ScreenViewer
```

Or drag `ScreenViewer` from Applications onto the Dock.

**3. First launch.** Allow **Local Network** access when macOS asks. If it never asks, turn it on under System Settings > Privacy & Security > Local Network.

## Daily use

1. Plug in the cable (the first time after boot, wait up to a minute for the automatic addresses)
2. Windows: make sure the tray app is running and `Win+P` is on **Extend**
3. Mac: open **ScreenViewer**
4. The title changes from "waiting for Windows..." to "Screen Viewer" by itself

Fullscreen: **Ctrl+Cmd+F**. Close the viewer window to quit it.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Mac stays on "waiting for Windows..." | Check the tray app is running, `Win+P` is on Extend, and the cable is plugged in. After a reboot, quit the tray app and start it again, because ffmpeg can start before the virtual monitor is ready. |
| Log shows `Failed to enumerate DXGI output 1` | The virtual monitor is not extended. Press `Win+P` and choose Extend. |
| A second, delayed Windows cursor trails the Mac cursor | Make sure `C:\VirtualDisplayDriver\vdd_settings.xml` has `<HardwareCursor>true</HardwareCursor>`, then reload the driver. |
| Stutter or lag | Use the cable, not Wi-Fi. Try a lower resolution (1920x1080) or a lower bitrate. |
| Mouse clicks do nothing on the Mac | Check the log for `input connected from ...`. If it says `no second screen`, the virtual monitor is off. |

## Security notes

Video and input travel unencrypted over the cable. The host only accepts input from `169.254.x.x` and `192.168.50.x` addresses, and the firewall rule above is limited to the same ranges. Don't open these ports to other networks.

## Limitations

- The Windows cursor on the Mac is the standard Mac arrow, so it does not change shape
- No audio
- One Mac at a time
- Tested only with Intel QuickSync on Windows and an M1 Mac

## Credits

- [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver) by VirtualDrivers, which provides the virtual monitor (see its repository for its license)
- [FFmpeg](https://ffmpeg.org/), which is not bundled here. Its license depends on the build you install.

## License

MIT
