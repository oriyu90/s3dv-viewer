#!/usr/bin/env bash
# verify_dmg.sh — mounts a built DMG read-only and asserts the release contract.
#
#   scripts/verify_dmg.sh [path/to/S3DV-viewer-<version>.dmg]
#
# With no argument the newest dist/S3DV-viewer-*.dmg is used. Prints a PASS/FAIL
# table and exits non-zero if anything fails. The volume is always detached.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DIST="$ROOT/dist"

DMG="${1:-}"
if [ -z "$DMG" ]; then
  DMG="$(ls -t "$DIST"/S3DV-viewer-*.dmg 2>/dev/null | head -1 || true)"
fi
[ -n "$DMG" ] || { echo "ERROR: no dist/S3DV-viewer-*.dmg found; run scripts/make_dmg.sh" >&2; exit 1; }
[ -f "$DMG" ] || { echo "ERROR: $DMG not found" >&2; exit 1; }
DMG="$(cd "$(dirname "$DMG")" && pwd -P)/$(basename "$DMG")"

MNT="$(mktemp -d "${TMPDIR:-/tmp}/s3dv-verify.XXXXXX")"
ROWSPILE="$(mktemp "${TMPDIR:-/tmp}/s3dv-verify-rows.XXXXXX")"
ATTACHED=0
FAILS=0

cleanup() {
  local rc=$?
  if [ "$ATTACHED" = 1 ]; then
    if ! hdiutil detach "$MNT" -quiet >/dev/null 2>&1; then
      hdiutil detach "$MNT" -force -quiet >/dev/null 2>&1 ||
        echo "WARN: could not detach $MNT" >&2
    fi
  fi
  rmdir "$MNT" 2>/dev/null || true
  rm -f "$ROWSPILE"
  return "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

row() { # row <PASS|FAIL|INFO> <check> <detail>
  if [ "$1" = FAIL ]; then FAILS=$((FAILS + 1)); fi
  printf '%-4s\t%-31s\t%s\n' "$1" "$2" "$3" >> "$ROWSPILE"
}

# ------------------------------------------------------------------ image ----

BASE="$(basename "$DMG" .dmg)"
WANT_VERSION="${BASE#S3DV-viewer-}"
if [ "$WANT_VERSION" = "$BASE" ]; then
  row FAIL "output filename" "expected S3DV-viewer-<version>.dmg, got $(basename "$DMG")"
else
  row PASS "output filename" "$(basename "$DMG") (version $WANT_VERSION)"
fi

if hdiutil verify "$DMG" >/dev/null 2>&1; then
  row PASS "hdiutil verify" "checksums and partition table OK"
else
  row FAIL "hdiutil verify" "hdiutil verify failed"
fi

if hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -quiet -mountpoint "$MNT" >/dev/null 2>&1; then
  ATTACHED=1
  row PASS "mount (read-only)" "$MNT"
else
  row FAIL "mount (read-only)" "could not mount $DMG"
  printf '%-4s %-31s %s\n' "RSLT" "CHECK" "DETAIL"
  awk -F'\t' '{ printf "%-4s %-31s %s\n", $1, $2, $3 }' "$ROWSPILE"
  echo ""
  echo "FAILED: image could not be mounted"
  exit 1
fi

# ------------------------------------------------------------- contents ------

# Exactly one top-level .app bundle (name follows CFBundleName).
APP=""
APP_COUNT=0
for cand in "$MNT"/*.app; do
  [ -d "$cand" ] || continue
  APP_COUNT=$((APP_COUNT + 1))
  APP="$cand"
done

if [ "$APP_COUNT" -eq 1 ]; then
  row PASS "app bundle present" "$(basename "$APP")"
elif [ "$APP_COUNT" -eq 0 ]; then
  row FAIL "app bundle present" "no .app at the volume root"
else
  row FAIL "app bundle present" "$APP_COUNT .app bundles at the volume root"
fi

if [ -n "$APP" ]; then
  if [ -f "$APP/Contents/Info.plist" ] &&
     plutil -lint "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    row PASS "Info.plist parses" "Contents/Info.plist"
  else
    row FAIL "Info.plist parses" "missing or malformed Contents/Info.plist"
  fi

  EXEC_REL="S3DVViewer"
  if [ ! -x "$APP/Contents/MacOS/S3DVViewer" ]; then
    EXEC_REL="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
      "$APP/Contents/Info.plist" 2>/dev/null || true)"
    EXEC_REL="${EXEC_REL:-S3DVViewer}"
  fi
  if [ -x "$APP/Contents/MacOS/$EXEC_REL" ]; then
    row PASS "executable bit" "Contents/MacOS/$EXEC_REL"
  else
    row FAIL "executable bit" "Contents/MacOS/$EXEC_REL missing or not executable"
  fi

  GOT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$GOT_VERSION" = "$WANT_VERSION" ]; then
    row PASS "version matches filename" "CFBundleShortVersionString=$GOT_VERSION"
  else
    row FAIL "version matches filename" "plist='${GOT_VERSION:-<none>}' filename='$WANT_VERSION'"
  fi

  if codesign --verify --strict "$APP" >/dev/null 2>&1; then
    # Capture first: piping codesign into `grep -q` trips pipefail via SIGPIPE.
    SIGINFO="$(codesign -dv "$APP" 2>&1 || true)"
    case "$SIGINFO" in
      *Signature=adhoc*) row PASS "code signature" "verifies (ad-hoc, not notarized)" ;;
      *) row PASS "code signature" "verifies" ;;
    esac
  else
    row FAIL "code signature" "codesign --verify --strict failed"
  fi
fi

APP_BIN="$APP/Contents/MacOS/S3DVViewer"
if [ -f "$APP_BIN" ]; then
  ARCHS="$(lipo -archs "$APP_BIN" 2>/dev/null || echo unknown)"
  case "$ARCHS" in
    *arm64*) row PASS "architecture" "$ARCHS" ;;
    *) row FAIL "architecture" "expected arm64, got $ARCHS" ;;
  esac
fi

CTL="$APP/Contents/MacOS/s3dvctl"
if [ -x "$CTL" ] && [ -n "$(file -b "$CTL" | grep -o 'Mach-O')" ]; then
  row PASS "cli companion" "Contents/MacOS/s3dvctl"
else
  row FAIL "cli companion" "missing or not executable"
fi

WEB="$APP/Contents/Resources/web"
missing=""
for f in index.html main.js viewer.html viewer.js vendor/three.module.js vendor/three.core.js vendor/controls/OrbitControls.js; do
  [ -s "$WEB/$f" ] || missing="$missing $f"
done
if [ -z "$missing" ]; then
  row PASS "bundled web assets" "$(ls "$WEB" | tr '\n' ' ')"
else
  row FAIL "bundled web assets" "missing:$missing"
fi

LINK="$MNT/Applications"
if [ -L "$LINK" ]; then
  TARGET="$(readlink "$LINK")"
  if [ "$TARGET" = "/Applications" ]; then
    row PASS "Applications symlink" "-> /Applications"
  else
    row FAIL "Applications symlink" "points at '$TARGET', expected /Applications"
  fi
else
  row FAIL "Applications symlink" "missing (or not a symlink)"
fi

for f in README.txt LICENSES.txt; do
  if [ -s "$MNT/$f" ]; then
    row PASS "$f" "$(wc -c <"$MNT/$f" | tr -d ' ') bytes"
  else
    row FAIL "$f" "missing or empty"
  fi
done

if [ -s "$MNT/.background/background.png" ]; then
  row PASS ".background/background.png" "$(wc -c <"$MNT/.background/background.png" | tr -d ' ') bytes"
else
  row FAIL ".background/background.png" "missing or empty"
fi

# Finder layout is best-effort (see DMG.md), so this is informational only.
if [ -s "$MNT/.DS_Store" ]; then
  row INFO "Finder layout" ".DS_Store present ($(wc -c <"$MNT/.DS_Store" | tr -d ' ') bytes)"
else
  row INFO "Finder layout" "no .DS_Store — plain layout was used"
fi

# ----------------------------------------------------------------- report ----

printf '%-4s %-31s %s\n' "RSLT" "CHECK" "DETAIL"
awk -F'\t' '{ printf "%-4s %-31s %s\n", $1, $2, $3 }' "$ROWSPILE"
echo ""
echo "image: $DMG ($(du -h "$DMG" | cut -f1), $(stat -f %z "$DMG") bytes)"

hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || hdiutil detach "$MNT" -force -quiet >/dev/null 2>&1 || true
ATTACHED=0
if mount | grep -qF "on $MNT " 2>/dev/null; then
  echo "WARN: $MNT is still mounted" >&2
fi

if [ "$FAILS" -gt 0 ]; then
  echo "FAIL: $FAILS check(s) failed"
  exit 1
fi
echo "PASS: all checks passed"
