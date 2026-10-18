#!/usr/bin/env bash
# uninstall.sh — stop Needle and remove what install.sh added. Settings and the cover cache are kept
# unless you pass --all (they are small: ~/Library/Caches/com.greggaynor.needle and one defaults suite).
set -euo pipefail

BUNDLE_ID="com.greggaynor.needle"
launchctl bootout "gui/$UID/${BUNDLE_ID}" >/dev/null 2>&1 || true
pkill -x Needle >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"
[ -L "$HOME/.local/bin/needle" ] && rm -f "$HOME/.local/bin/needle"
rm -rf "$HOME/Applications/Needle.app"
if [ "${1:-}" = "--all" ]; then
  rm -rf "$HOME/Library/Caches/${BUNDLE_ID}"
  defaults delete "${BUNDLE_ID}.settings" >/dev/null 2>&1 || true
fi
echo "Needle removed${1:+ (with its settings and cache)}."
