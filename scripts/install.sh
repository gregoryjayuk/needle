#!/usr/bin/env bash
# install.sh — build Needle, bundle it into ~/Applications/Needle.app, start it at login, and put the
# `needle` command in ~/.local/bin. Safe to re-run: every step is idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Needle"
BUNDLE_ID="com.greggaynor.needle"
VERSION="1.0.1"
APP_BUNDLE="$HOME/Applications/${APP_NAME}.app"
APP_EXEC="$APP_BUNDLE/Contents/MacOS/${APP_NAME}"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"
WORK="$PKG_DIR/.build/bundle"

echo "▸ building (release)"
cd "$PKG_DIR"
swift build -c release 2>&1 | grep -E "error|warning: unre|Build complete" || true
test -x ".build/release/${APP_NAME}" || { echo "build failed" >&2; exit 1; }

echo "▸ icon"
rm -rf "$WORK" && mkdir -p "$WORK"
".build/release/${APP_NAME}" --render-icon "$WORK/${APP_NAME}.iconset"
iconutil -c icns "$WORK/${APP_NAME}.iconset" -o "$WORK/${APP_NAME}.icns"

echo "▸ bundling → $APP_BUNDLE"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
mkdir -p "$HOME/Applications" "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp ".build/release/${APP_NAME}" "$APP_EXEC"
chmod +x "$APP_EXEC"
cp "$WORK/${APP_NAME}.icns" "$APP_BUNDLE/Contents/Resources/${APP_NAME}.icns"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>        <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>         <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>         <string>${BUNDLE_ID}</string>
  <key>CFBundleIconFile</key>           <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
  <key>CFBundleVersion</key>            <string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key>     <string>14.0</string>
  <key>LSUIElement</key>                <true/>
  <key>NSHighResolutionCapable</key>    <true/>
  <key>NSHumanReadableCopyright</key>   <string>GPL-2.0</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Needle plays your MPD music server on the home network.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || echo "  (ad-hoc codesign skipped)"

echo "▸ command line → ~/.local/bin/needle"
mkdir -p "$HOME/.local/bin"
ln -sf "$APP_EXEC" "$HOME/.local/bin/needle"

echo "▸ LaunchAgent → $LAUNCH_AGENT"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>${BUNDLE_ID}</string>
  <key>ProgramArguments</key>  <array><string>${APP_EXEC}</string></array>
  <key>RunAtLoad</key>         <true/>
  <key>KeepAlive</key>         <dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key>       <string>Interactive</string>
  <key>StandardOutPath</key>   <string>/tmp/${BUNDLE_ID}.out.log</string>
  <key>StandardErrorPath</key> <string>/tmp/${BUNDLE_ID}.err.log</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$UID/${BUNDLE_ID}" >/dev/null 2>&1 || true
sleep 0.5
launchctl bootstrap "gui/$UID" "$LAUNCH_AGENT"
launchctl enable "gui/$UID/${BUNDLE_ID}" || true
sleep 1.5
if pgrep -x "$APP_NAME" >/dev/null; then
  echo "▸ running (pid $(pgrep -x "$APP_NAME" | head -1)); the record-player bars are in the menu bar"
  echo "  First run: macOS asks whether Needle may find devices on your local network — Allow, or it cannot reach the server."
else
  echo "▸ NOT running — check /tmp/${BUNDLE_ID}.err.log and ~/Library/Logs/needle.log" >&2
  exit 1
fi
