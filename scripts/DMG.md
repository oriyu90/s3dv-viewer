# S3DV viewer — DMG packaging

Builds `dist/S3DV-viewer-<version>.dmg` (UDZO) containing the app bundle, an
`/Applications` symlink, `README.txt`, `LICENSES.txt` and a Finder background.

```
scripts/build_app.sh          # produces build/S3DV viewer.app (ad-hoc signed)
scripts/make_dmg.sh --check   # validate prerequisites, print the plan, build nothing
scripts/make_dmg.sh           # build + hdiutil verify + verify_dmg.sh
scripts/verify_dmg.sh [dmg]   # re-check an existing image (default: newest in dist/)
```

`make_dmg.sh` is `set -euo pipefail`, quotes every path (the repo path contains
Japanese characters, the app name contains a space), and cleans up through a
`trap` on EXIT/INT/TERM: the mounted volume is always detached and `build/dmg`
is removed. `S3DV_DMG_KEEP_WORK=1` keeps the staging directory for inspection.

## Version source

The image name comes from `CFBundleShortVersionString` in
`apps/s3dv-viewer/Info.plist`. The staged bundle's own version is compared
against it; a mismatch aborts the build, because it means `build_app.sh` was not
re-run after a version bump and the release would be mislabeled:

```
ERROR: stale build: S3DV viewer.app reports 0.1.0 but Info.plist says 1.0.0
       — run scripts/build_app.sh (or set S3DV_VERSION_FROM_BUNDLE=1 ...)
```

`S3DV_VERSION_FROM_BUNDLE=1` packages the bundle as-is at its own version (used
while the sources were mid-rename). The bundle name is resolved from
`CFBundleName`, then the literal `S3DV viewer.app` / `S3DV Viewer.app`; the
volume gets the bundle's file name. `S3DV_APP_PATH` overrides the source.

## Volume layout

| item | note |
| --- | --- |
| `S3DV viewer.app` | copied with `ditto` (signature, xattrs preserved) |
| `Applications` | symlink to `/Applications` |
| `README.txt` | Japanese: drag-to-install, Gatekeeper workarounds, issue contact |
| `LICENSES.txt` | three.js r180 (MIT), PLATEAU / 東京都デジタルツイン基盤 (CC BY 4.0) |
| `.background/background.png` | Finder background (1280×800, served at 640×400 pt) |
| `.DS_Store` | window layout written by Finder |

Finder window: 640×400 (bounds `{120,120,760,520}`), icon view, app at
`(170,190)`, Applications at `(470,190)`.

## How the layout is applied

1. `hdiutil create -srcfolder ... -format UDRW` → attach read-write.
2. The image is mounted under `/Volumes` (not a custom `-mountpoint`): Finder
   only scripts volumes it sees as disks, and a volume mounted elsewhere is
   silently ignored.
3. `osascript` sets background picture, arrangement, icon size, icon positions
   and window bounds, then closes the window so Finder flushes `.DS_Store`.
   The script is passed as a **file** — a backgrounded job gets `/dev/null` on
   stdin, which would feed `osascript -` an empty script and "succeed" silently.
4. Detach, `hdiutil convert -format UDZO -imagekey zlib-level=9`.

Before attaching, any volume already mounted as `S3DV viewer <version>` (or the
` 1`, ` 2` collision suffixes) is detached, otherwise the new image is shadowed
at the same `/Volumes` path and Finder would edit the wrong volume.

### Fallback

`osascript` runs under a watchdog (`--finder-timeout=SEC`, default 30). If it
times out or fails, the run prints `WARN`, removes any partial `.DS_Store`, and
continues with a plain layout; the image is still built and verified. The chosen
path is reported as `layout: scripted` / `layout: plain`. `--finder=plain` skips
scripting, `--finder=script` still falls back rather than failing the build.

### macOS quirks found while building this

- `set icon size` / `set text size` are accepted but not persisted for
  disk-image windows on macOS 26/27: Finder writes the default 48 pt into
  `.DS_Store`. Window bounds, icon positions, icon view and background picture
  do persist. Icon size is therefore best-effort; do not rely on it.
- `set background picture` must run **before** `set icon size` — the reverse
  order resets the icon size.
- Only `background.png` may live in `.background/`. Adding `background@2x.png`
  makes Finder ignore the scripted icon size. The `@2x` asset is kept in
  `assets/dmg/` for other uses but is not copied into the image.
- The ad-hoc signature survives `ditto` + `hdiutil convert`; it is not
  notarized by policy, hence the Gatekeeper instructions in `README.txt`.

## Background art

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift scripts/make_dmg_background.swift [--scale 2] [--out-dir assets/dmg] [--icon PATH|--no-icon]
```

AppKit/CoreGraphics offscreen render, no external assets except
`assets/AppIcon.icns` (a drawn cube is used with `--no-icon`). Layout is
expressed in 640×400 Finder coordinates and multiplied by `--scale`, so the art
lines up with the scripted icon positions. Output is deterministic: two runs
produce byte-identical PNGs (verified by sha256), and `--scale 2` writes
`background.png` and `background@2x.png` (both 1280×800).

## Verification

`scripts/verify_dmg.sh [dmg]` mounts the image read-only and prints a PASS/FAIL
table; any FAIL exits non-zero. Checks: output filename carries the version,
`hdiutil verify`, read-only mount, exactly one `.app` at the volume root,
`Info.plist` parses, `Contents/MacOS/S3DVViewer` is executable,
`CFBundleShortVersionString` equals the version in the filename,
`codesign --verify --strict`, `Applications -> /Applications`, non-empty
`README.txt` / `LICENSES.txt` / `.background/background.png`. `.DS_Store` is
reported as INFO because the layout is best-effort. The volume is always
detached.

## Validation notes

The pipeline was validated end-to-end against the real
`build/S3DV viewer.app` produced by `build_app.sh`; no stub bundle is shipped or
referenced here. A throwaway stub (`Info.plist` + `/bin/echo` as
`Contents/MacOS/S3DVViewer` + empty `Contents/Resources`, `codesign --force
--sign -`) is a valid substitute when `build_app.sh` has not run yet — point
`S3DV_APP_PATH` at it. The current `dist/S3DV-viewer-1.0.0.dmg` contains the
real app.

## Residual risk

- The image is ad-hoc signed and not notarized by design; the first launch needs
  the right-click → 開く or `xattr -dr com.apple.quarantine` path documented in
  `README.txt`.
- If Automation consent is ever revoked, builds silently downgrade to the plain
  layout (WARN + `layout: plain`); the image stays valid.
- Finder layout depends on the user's Finder being scriptable; CI/headless runs
  without a logged-in Aqua session will take the fallback path.
