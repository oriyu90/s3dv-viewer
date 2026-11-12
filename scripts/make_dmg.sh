#!/usr/bin/env bash
# make_dmg.sh — builds apps/s3dv-viewer/dist/S3DV-viewer-<version>.dmg
#
# The image contains the app bundle, an /Applications symlink, README.txt,
# LICENSES.txt and .background/background.png. A Finder layout (640x400 window,
# icon view, background picture, icon positions) is applied by scripting Finder
# on a writable UDRW image which is then converted to UDZO. When Automation
# consent is unavailable the run degrades to a plain layout with a WARN and
# still produces a verified image.
#
# Requires: hdiutil, PlistBuddy, ditto, osascript (optional), swift (optional,
# only to regenerate the background art).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PLIST="$ROOT/Info.plist"
ASSETS="$ROOT/assets/dmg"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
BG_SWIFT="$ROOT/scripts/make_dmg_background.swift"
VERIFY="$ROOT/scripts/verify_dmg.sh"

MODE_CHECK=0
RUN_VERIFY=1
FINDER_MODE="${S3DV_DMG_FINDER:-auto}"          # auto | script | plain
FINDER_TIMEOUT="${S3DV_DMG_FINDER_TIMEOUT:-30}" # seconds
APPLICATIONS_TARGET="/Applications"

WORK="$BUILD/dmg"
MNT=""
ATTACHED=0
LAYOUT="none"

log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
usage: scripts/make_dmg.sh [options]

  --check               validate prerequisites and print the plan; build nothing
  --finder=auto|script|plain
                        Finder window layout. auto (default) tries Finder
                        scripting and falls back to a plain layout.
  --finder-timeout=SEC  seconds to wait for Finder scripting (default 30)
  --no-verify           skip scripts/verify_dmg.sh at the end
  -h, --help            show this help

environment:
  S3DV_APP_PATH           explicit app bundle to package
  S3DV_DMG_FINDER         same as --finder
  S3DV_DMG_FINDER_TIMEOUT same as --finder-timeout
  S3DV_DMG_KEEP_WORK=1    keep build/dmg for inspection
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE_CHECK=1 ;;
    --finder=*) FINDER_MODE="${1#*=}" ;;
    --finder) shift; FINDER_MODE="${1:-}" ;;
    --finder-timeout=*) FINDER_TIMEOUT="${1#*=}" ;;
    --no-verify) RUN_VERIFY=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

case "$FINDER_MODE" in
  auto|script|plain) ;;
  *) die "--finder must be auto, script or plain (got: $FINDER_MODE)" ;;
esac
case "$FINDER_TIMEOUT" in
  ''|*[!0-9]*) die "--finder-timeout must be a whole number of seconds" ;;
esac

# ---------------------------------------------------------------- cleanup ---

cleanup() {
  local rc=$?
  if [ "$ATTACHED" = 1 ] && [ -n "$MNT" ]; then
    if ! hdiutil detach "$MNT" -quiet >/dev/null 2>&1; then
      hdiutil detach "$MNT" -force -quiet >/dev/null 2>&1 ||
        warn "could not detach $MNT — detach it manually: hdiutil detach \"$MNT\" -force"
    fi
    ATTACHED=0
  fi
  case "$MNT" in
    "$WORK"/*) [ -n "$MNT" ] && rmdir "$MNT" 2>/dev/null || true ;;
  esac
  if [ "$MODE_CHECK" = 0 ] && [ "${S3DV_DMG_KEEP_WORK:-0}" != 1 ]; then
    case "$WORK" in
      "$BUILD"/dmg) rm -rf -- "$WORK" ;;
      *) warn "refusing to remove unexpected staging path: $WORK" ;;
    esac
  fi
  return "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ------------------------------------------------------------------ inputs ---

command -v hdiutil >/dev/null 2>&1 || die "hdiutil not found"
[ -f "$PLIST" ] || die "missing $PLIST"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
[ -n "$VERSION" ] || die "CFBundleShortVersionString missing from $PLIST"
case "$VERSION" in
  *[!0-9A-Za-z._-]*) die "unexpected version string in Info.plist: '$VERSION'" ;;
esac

VOLNAME="S3DV viewer $VERSION"
OUT="$DIST/S3DV-viewer-$VERSION.dmg"
BUNDLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$PLIST" 2>/dev/null || true)"

APP_SRC=""
resolve_app() {
  local cand
  if [ -n "${S3DV_APP_PATH:-}" ]; then
    [ -d "$S3DV_APP_PATH" ] || die "S3DV_APP_PATH is not a bundle: $S3DV_APP_PATH"
    APP_SRC="$S3DV_APP_PATH"
    return 0
  fi
  # CFBundleName first (the bundle is mid-rename from "S3DV Viewer" to
  # "S3DV viewer"), then both literal spellings as a fallback.
  for cand in "$BUILD/${BUNDLE_NAME:-S3DV viewer}.app" \
              "$BUILD/S3DV viewer.app" \
              "$BUILD/S3DV Viewer.app"; do
    if [ -d "$cand" ]; then
      APP_SRC="$cand"
      return 0
    fi
  done
  return 1
}

if resolve_app; then
  APP_NAME="$(basename "$APP_SRC")"
  APP_PLIST="$APP_SRC/Contents/Info.plist"
  APP_EXEC=""
  if [ -f "$APP_PLIST" ]; then
    APP_EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PLIST" 2>/dev/null || true)"
  fi
  APP_EXEC="${APP_EXEC:-S3DVViewer}"
else
  APP_NAME="${BUNDLE_NAME:-S3DV viewer}.app"
  APP_EXEC="S3DVViewer"
fi

# ------------------------------------------------------------------- check ---

if [ "$MODE_CHECK" = 1 ]; then
  fail=0
  chk() { # chk <label> <ok|missing> [detail]
    printf '  %-7s %-26s %s\n' "$2" "$1" "${3:-}"
    [ "$2" = "ok" ] || fail=$((fail + 1))
  }
  have() { command -v "$1" >/dev/null 2>&1 && echo ok || echo missing; }

  log "S3DV viewer — DMG plan"
  log ""
  printf '  %-11s %s\n' "version" "$VERSION"
  printf '  %-11s %s\n' "source app" "${APP_SRC:-$BUILD/$APP_NAME (not built yet)}"
  printf '  %-11s %s\n' "volume" "$VOLNAME"
  printf '  %-11s %s\n' "layout" "640x400 icon view, app @ (170,190), Applications @ (470,190)"
  printf '  %-11s %s\n' "finder" "$FINDER_MODE (timeout ${FINDER_TIMEOUT}s; falls back to plain layout)"
  printf '  %-11s %s\n' "output" "$OUT (UDZO)"
  printf '  %-11s %s\n' "contents" "$APP_NAME, Applications -> $APPLICATIONS_TARGET, README.txt, LICENSES.txt, .background/background.png"
  log ""
  log "prerequisites:"
  chk "hdiutil" "$(have hdiutil)"
  chk "PlistBuddy" "$([ -x /usr/libexec/PlistBuddy ] && echo ok || echo missing)"
  chk "ditto" "$(have ditto)"
  chk "osascript" "$(have osascript)" "Automation consent is not probed (would show a dialog)"
  chk "swift" "$(have swift)" "only needed to regenerate the background art"
  if [ -d "$APP_SRC" ]; then
    chk "app bundle" ok "$APP_SRC"
    if [ -x "$APP_SRC/Contents/MacOS/$APP_EXEC" ]; then
      chk "executable" ok "Contents/MacOS/$APP_EXEC"
    else
      chk "executable" missing "Contents/MacOS/$APP_EXEC"
    fi
    BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
      "$APP_SRC/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$BUILT_VERSION" = "$VERSION" ]; then
      chk "bundle version" ok "$BUILT_VERSION matches Info.plist"
    else
      chk "bundle version" missing "bundle=$BUILT_VERSION plist=$VERSION — rebuild or S3DV_VERSION_FROM_BUNDLE=1"
    fi
    if codesign --verify --strict "$APP_SRC" >/dev/null 2>&1; then
      chk "signature" ok "ad-hoc, verifies"
    else
      chk "signature" missing "codesign --verify --strict failed"
    fi
  else
    chk "app bundle" missing "run scripts/build_app.sh first"
  fi
  for f in background.png README.txt LICENSES.txt; do
    if [ -s "$ASSETS/$f" ]; then
      chk "$f" ok "$(wc -c <"$ASSETS/$f" | tr -d ' ') bytes"
    else
      chk "$f" missing "$ASSETS/$f"
    fi
  done
  [ -d "$DIST" ] || mkdir -p "$DIST" 2>/dev/null || true
  chk "dist dir" "$([ -w "$DIST" ] && echo ok || echo missing)" "$DIST"
  if [ -d "/Volumes/$VOLNAME" ]; then
    chk "stale mount" ok "/Volumes/$VOLNAME mounted; it will be detached first"
  fi
  log ""
  if [ "$fail" -gt 0 ]; then
    log "check: $fail problem(s) — nothing was built"
    exit 1
  fi
  log "check: OK — nothing was built"
  exit 0
fi

# --------------------------------------------------------------- staging -----

[ -d "$APP_SRC" ] || die "app bundle missing: $BUILD/$APP_NAME (run scripts/build_app.sh first)"
[ -f "$ASSETS/README.txt" ] || die "missing $ASSETS/README.txt"
[ -f "$ASSETS/LICENSES.txt" ] || die "missing $ASSETS/LICENSES.txt"

if [ ! -s "$ASSETS/background.png" ]; then
  log "background art missing — rendering it"
  [ -f "$BG_SWIFT" ] || die "missing $BG_SWIFT"
  command -v swift >/dev/null 2>&1 || die "swift not found; cannot render background art"
  ( cd "$ROOT" && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      swift "$BG_SWIFT" --out-dir "$ASSETS" ) || die "background rendering failed"
fi

rm -rf -- "$WORK"
mkdir -p "$WORK/root" "$DIST"
SRC_STAGE="$WORK/root"
RW="$WORK/S3DV-viewer-rw.dmg"

log "staging $APP_NAME ($(du -sh "$APP_SRC" | cut -f1))"
copy_app() {
  local try
  for try in 1 2 3; do
    rm -rf -- "$SRC_STAGE/$APP_NAME"
    if ditto "$APP_SRC" "$SRC_STAGE/$APP_NAME" 2>/dev/null &&
       [ -x "$SRC_STAGE/$APP_NAME/Contents/MacOS/$APP_EXEC" ] &&
       plutil -lint "$SRC_STAGE/$APP_NAME/Contents/Info.plist" >/dev/null 2>&1; then
      return 0
    fi
    warn "app copy attempt $try looked incomplete (build_app.sh running?); retrying"
    sleep 2
  done
  die "could not copy a consistent app bundle from $APP_SRC"
}
copy_app

# The image name is derived from Info.plist, but what actually ships is the
# *built* bundle. A mismatch means build_app.sh was not re-run after a version
# bump, which would produce a mislabeled release.
STAGED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$SRC_STAGE/$APP_NAME/Contents/Info.plist" 2>/dev/null || true)"
if [ "$STAGED_VERSION" != "$VERSION" ]; then
  if [ "${S3DV_VERSION_FROM_BUNDLE:-0}" = 1 ]; then
    warn "app bundle says $STAGED_VERSION but Info.plist says $VERSION — packaging the bundle as $STAGED_VERSION (S3DV_VERSION_FROM_BUNDLE=1)"
    VERSION="$STAGED_VERSION"
    VOLNAME="S3DV viewer $VERSION"
    OUT="$DIST/S3DV-viewer-$VERSION.dmg"
  else
    die "stale build: $APP_NAME reports $STAGED_VERSION but $PLIST says $VERSION — run scripts/build_app.sh (or set S3DV_VERSION_FROM_BUNDLE=1 to package the bundle as-is)"
  fi
fi

# A stale mount with our volume name would shadow the new image at the same
# /Volumes path, so Finder scripting would silently edit the wrong volume.
# Cover "name" and the "name 1", "name 2" suffixes macOS adds on collision.
for stale in "/Volumes/$VOLNAME" "/Volumes/$VOLNAME "[0-9]*; do
  [ -d "$stale" ] || continue
  [ -d "$stale/$APP_NAME" ] || continue
  warn "volume already mounted at '$stale' — detaching it first"
  hdiutil detach "$stale" -force -quiet ||
    die "could not detach '$stale'; detach it manually and retry"
done

ln -s "$APPLICATIONS_TARGET" "$SRC_STAGE/Applications"
cp "$ASSETS/README.txt" "$SRC_STAGE/README.txt"
cp "$ASSETS/LICENSES.txt" "$SRC_STAGE/LICENSES.txt"
mkdir -p "$SRC_STAGE/.background"
cp "$ASSETS/background.png" "$SRC_STAGE/.background/background.png"
# Only background.png goes into .background: with a second image in that folder
# Finder ignores the scripted icon size and falls back to its default (48).
chmod 644 "$SRC_STAGE/README.txt" "$SRC_STAGE/LICENSES.txt" "$SRC_STAGE/.background/background.png"

# ------------------------------------------------------- writable image ------

hdiutil create -srcfolder "$SRC_STAGE" -volname "$VOLNAME" -fs HFS+ \
  -format UDRW -quiet "$RW" || die "hdiutil create (UDRW) failed"

# Finder can only script volumes it sees as disks, i.e. mounted under /Volumes.
# Mounting at an arbitrary -mountpoint silently produces no .DS_Store.
hdiutil attach "$RW" -readwrite -nobrowse -noautoopen -quiet ||
  die "hdiutil attach failed for $RW"
ATTACHED=1

resolve_mount() {
  local want="$1" c
  for c in "/Volumes/$want" "/Volumes/$want 1" "/Volumes/$want 2"; do
    if [ -d "$c/$APP_NAME" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}
MNT="$(resolve_mount "$VOLNAME" || true)"
[ -n "$MNT" ] || die "could not find the mounted volume under /Volumes for '$VOLNAME'"
[ -L "$MNT/Applications" ] || die "mounted image is missing the Applications symlink"

# --------------------------------------------------------- Finder layout -----

run_with_timeout() { # run_with_timeout <seconds> <cmd...>
  local secs="$1" pid n=0 rc=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$n" -ge "$secs" ]; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    n=$((n + 1))
  done
  wait "$pid" || rc=$?
  return "$rc"
}

finder_layout() { # finder_layout <volume-name> <app-bundle-name>
  # The script goes to a file: run_with_timeout backgrounds osascript, and a
  # backgrounded job's stdin is /dev/null, which would feed it an empty script.
  local script_file="$WORK/finder-layout.applescript"
  cat > "$script_file" <<'APPLESCRIPT'
on run argv
  set volName to item 1 of argv
  set appName to item 2 of argv
  tell application "Finder"
    tell disk volName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {120, 120, 760, 520}
      set opts to the icon view options of container window
      -- Background first: setting it *after* icon size resets the icon size
      -- back to the Finder default on the next open.
      set background picture of opts to file ".background:background.png"
      set arrangement of opts to not arranged
      set icon size of opts to 128
      set text size of opts to 12
      set position of item appName of container window to {170, 190}
      set position of item "Applications" of container window to {470, 190}
      update without registering applications
      delay 1
      close container window
    end tell
  end tell
  return "ok"
end run
APPLESCRIPT
  run_with_timeout "$FINDER_TIMEOUT" osascript "$script_file" "$VOLNAME" "$APP_NAME"
}

try_finder_layout() {
  local rc=0
  LAYOUT="plain"
  if [ "$FINDER_MODE" = plain ]; then
    warn "--finder=plain: skipping the scripted Finder layout"
    return 0
  fi
  log "applying Finder layout (timeout ${FINDER_TIMEOUT}s)"
  finder_layout "$VOLNAME" "$APP_NAME" || rc=$?
  # Finder flushes .DS_Store asynchronously once the window closes.
  local waited=0
  while [ "$waited" -lt 8 ] && [ ! -s "$MNT/.DS_Store" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$rc" -eq 0 ] && [ -s "$MNT/.DS_Store" ]; then
    LAYOUT="scripted"
    log "layout: scripted (.DS_Store written by Finder)"
    return 0
  fi
  if [ "$rc" -eq 124 ]; then
    warn "Finder scripting timed out after ${FINDER_TIMEOUT}s — Automation consent is probably not granted; using a plain layout"
  elif [ "$rc" -ne 0 ]; then
    warn "Finder scripting failed (exit $rc) — using a plain layout"
  else
    warn "Finder scripting reported success but wrote no .DS_Store — using a plain layout"
  fi
  rm -f "$MNT/.DS_Store"
  LAYOUT="plain"
  return 0
}
try_finder_layout

# ------------------------------------------------------------- freeze ---------

sync
sleep 1  # let Finder flush .DS_Store before the volume goes away
hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force -quiet ||
  die "could not detach $MNT"
ATTACHED=0
rmdir "$MNT" 2>/dev/null || true

rm -f -- "$OUT"
log "compressing (UDZO)"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -quiet -o "$WORK/final" ||
  die "hdiutil convert (UDZO) failed"
mv "$WORK/final.dmg" "$OUT"

hdiutil verify -quiet "$OUT" || die "hdiutil verify failed for $OUT"

log "dmg: $OUT"
log "size: $(du -h "$OUT" | cut -f1) ($(stat -f %z "$OUT") bytes)"
log "volume: $VOLNAME"
log "layout: $LAYOUT"

if [ "$RUN_VERIFY" = 1 ] && [ -f "$VERIFY" ]; then
  log ""
  bash "$VERIFY" "$OUT" || die "verification failed (see the table above)"
fi
