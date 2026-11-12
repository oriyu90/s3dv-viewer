#!/usr/bin/env bash
# Symlinks the bundled `s3dvctl` into a directory on PATH.
#
#   ./scripts/install_cli.sh            # /usr/local/bin (falls back to ~/bin)
#   ./scripts/install_cli.sh ~/bin
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${S3DV_APP_PATH:-$ROOT/build/S3DV viewer.app}"
CTL="$APP/Contents/MacOS/s3dvctl"
TARGET="${1:-/usr/local/bin}"

[ -x "$CTL" ] || { echo "ERROR: $CTL not found — run scripts/build_app.sh first" >&2; exit 1; }

if [ ! -d "$TARGET" ] || [ ! -w "$TARGET" ]; then
  FALLBACK="$HOME/bin"
  echo "note: $TARGET is not writable; using $FALLBACK" >&2
  mkdir -p "$FALLBACK"
  TARGET="$FALLBACK"
fi

ln -sf "$CTL" "$TARGET/s3dvctl"
echo "linked $TARGET/s3dvctl -> $CTL"
case ":$PATH:" in
  *":$TARGET:"*) ;;
  *) echo "note: add $TARGET to PATH to use 's3dvctl' directly" >&2 ;;
esac
"$TARGET/s3dvctl" help >/dev/null 2>&1 && echo "ok" || echo "note: the app is not running yet (that is fine)"
