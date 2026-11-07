#!/bin/bash
set -e
cd "$(dirname "$0")"
swiftc -O main.swift Discovery.swift Overlay.swift -o viewer
APP="ScreenViewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp viewer "$APP/Contents/MacOS/ScreenViewer"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Screen Viewer</string>
  <key>CFBundleDisplayName</key><string>Screen Viewer</string>
  <key>CFBundleIdentifier</key><string>me.kavija.screenviewer</string>
  <key>CFBundleExecutable</key><string>ScreenViewer</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Connects to your Windows PC over the cable to show its screen.</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
rm -rf /Applications/ScreenViewer.app
cp -R "$APP" /Applications/
echo "Installed: /Applications/ScreenViewer.app"
