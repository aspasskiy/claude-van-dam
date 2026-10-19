#!/bin/bash
# Build "Claude Van Dam.app"; `./build.sh --install` also copies it to /Applications and (re)launches it.
# `./build.sh --release` signs it with Developer ID, notarizes it and zips it for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Claude Van Dam"
EXE=ClaudeVanDam
LABEL=$(plutil -extract CFBundleIdentifier raw Info.plist)
VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
APP="build/$NAME.app"
MODE="${1:-}"
# Release signing: the Developer ID identity in the login keychain and a notarytool profile
# saved once with `xcrun notarytool store-credentials claude-van-dam --key … --key-id … --issuer …`.
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: OCTAGONLAB LIMITED (6966J92GMC)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-claude-van-dam}"

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
if [[ $MODE != --release ]]; then
    codesign --force --sign - "$APP" >/dev/null
    echo "built $APP"
    [[ $MODE == --install ]] || exit 0
else
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
    ZIP="build/Claude-Van-Dam-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    LOG=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait | tee /dev/stderr)
    if ! grep -q "status: Accepted" <<<"$LOG"; then
        echo "notarization failed; details: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi
    xcrun stapler staple "$APP"
    spctl -a -vv -t exec "$APP"
    # Zip again so the download carries the stapled ticket.
    rm "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "released $ZIP"
    shasum -a 256 "$ZIP"
    exit 0
fi

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
