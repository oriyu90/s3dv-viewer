#!/usr/bin/env bash
# Assembles S3DV viewer.app from `swift build -c release` output:
#   - copies the executable,
#   - flattens the SPM resource bundle into Contents/Resources,
#   - stamps Info.plist / PkgInfo / icon,
#   - ad-hoc code-signs (research kit; no notarization).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="S3DV viewer"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
SPM="$ROOT/.build/release"

cd "$ROOT"
swift build -c release

BIN="$SPM/S3DVViewer"
[ -x "$BIN" ] || { echo "ERROR: executable missing at $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/S3DVViewer"

# CLI companion: same bundle so `S3DV viewer.app/Contents/MacOS/s3dvctl` always
# matches the app that is running.
CTL="$SPM/s3dvctl"
[ -x "$CTL" ] || { echo "ERROR: s3dvctl missing at $CTL" >&2; exit 1; }
cp "$CTL" "$APP/Contents/MacOS/s3dvctl"

# SPM resource bundle -> app Resources
BUNDLE=""
for _b in "$SPM"/S3DVViewer_*.bundle; do
  if [ -d "$_b" ]; then BUNDLE="$_b"; break; fi
done
[ -n "$BUNDLE" ] || { echo "ERROR: SPM resource bundle not found in $SPM" >&2; exit 1; }
if [ -d "$BUNDLE/Contents/Resources" ]; then
  cp -R "$BUNDLE/Contents/Resources/." "$APP/Contents/Resources/"
else
  cp -R "$BUNDLE/." "$APP/Contents/Resources/"
fi
# .copy("Resources") leaves one extra nesting level; flatten it.
if [ -d "$APP/Contents/Resources/Resources" ]; then
  cp -R "$APP/Contents/Resources/Resources/." "$APP/Contents/Resources/"
  rm -rf "$APP/Contents/Resources/Resources"
fi

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f "$ROOT/assets/AppIcon.icns" ]; then
  cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/"
fi

codesign --force --sign - --timestamp=none "$APP"
plutil -lint "$APP/Contents/Info.plist"

# sanity: the web assets must exist where AppState.webRoot expects them
for f in index.html main.js viewer.html viewer.js vendor/three.module.js; do
  [ -f "$APP/Contents/Resources/web/$f" ] || {
    echo "ERROR: web/$f not bundled (run scripts/sync_web.sh?)" >&2; exit 1;
  }
done
echo "built: $APP"
