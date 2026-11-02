#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel) UnifiedInbox.app into ./dist
# Usage: ./scripts/build-app.sh [--debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
[[ "${1:-}" == "--debug" ]] && CONFIG=debug

swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product UnifiedInbox
swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product inboxctl
BIN="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)/UnifiedInbox"

APP=dist/UnifiedInbox.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UnifiedInbox"
# Command-line tool / MCP server (Settings → Privacy → Command line & AI assistants)
cp "$(dirname "$BIN")/inboxctl" "$APP/Contents/MacOS/inboxctl"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# App icon (regenerate with: python3 scripts/make_icon.py)
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Refresh Finder/Dock icon cache for this bundle
touch "$APP"

# Ad-hoc sign so macOS keeps the Full Disk Access grant stable between launches.
# Replace "-" with your Developer ID identity for distribution (and notarize).
codesign --force --deep --options runtime --sign - "$APP"

echo "Built $APP"
echo "First run: System Settings → Privacy & Security → Full Disk Access → add UnifiedInbox.app"
