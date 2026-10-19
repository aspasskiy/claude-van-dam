#!/bin/bash
# Build "Claude Van Dam.app"; `./build.sh --install` also copies it to /Applications and (re)launches it.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Claude Van Dam"
EXE=ClaudeVanDam
LABEL=$(plutil -extract CFBundleIdentifier raw Info.plist)
APP="build/$NAME.app"

swift build -c release --product "$EXE"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$EXE" "$APP/Contents/MacOS/$EXE"
cp Info.plist "$APP/Contents/Info.plist"
# App icon from Resources/AppIcon.png (redraw it with `swift tools/make-icon.swift Resources/AppIcon.png`).
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"

[[ "${1:-}" == "--install" ]] || exit 0

DEST="/Applications/$NAME.app"
AGENT=~/Library/LaunchAgents/$LABEL.plist
# With Launch at Login on, launchd owns the process: restart it there
# instead of racing KeepAlive with a second copy.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x "$EXE" || true

# Builds from before the renames (Refill, Claude Monet): retire their login item and app.
for OLD_LABEL in site.spasskiy.csbar site.spasskiy.claude-monet; do
    if [[ -f ~/Library/LaunchAgents/$OLD_LABEL.plist ]]; then
        launchctl bootout "gui/$(id -u)/$OLD_LABEL" 2>/dev/null || true
        rm -f ~/Library/LaunchAgents/$OLD_LABEL.plist
        WANT_AGENT=1
    fi
done
pkill -x Refill || true
pkill -x ClaudeMonet || true
rm -rf /Applications/Refill.app "/Applications/Claude Monet.app"

rm -rf "$DEST"
cp -R "$APP" /Applications/
if [[ -f $AGENT || -n "${WANT_AGENT:-}" ]]; then
    plutil -create xml1 "$AGENT.tmp" 2>/dev/null || true
    [[ -f $AGENT ]] && cp "$AGENT" "$AGENT.tmp"
    plutil -replace Label -string "$LABEL" "$AGENT.tmp"
    plutil -replace ProgramArguments -json "[\"$DEST/Contents/MacOS/$EXE\"]" "$AGENT.tmp"
    plutil -replace RunAtLoad -bool true "$AGENT.tmp"
    plutil -replace KeepAlive -json '{"SuccessfulExit": false}' "$AGENT.tmp"
    plutil -replace ProcessType -string Interactive "$AGENT.tmp"
    mv "$AGENT.tmp" "$AGENT"
    launchctl bootstrap "gui/$(id -u)" "$AGENT"
else
    open "$DEST"
fi
echo "installed $DEST"
