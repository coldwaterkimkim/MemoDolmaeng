#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
EXECUTABLE_NAME="MemoDolmaeng"
DISPLAY_NAME="울트라돌맹의포스트잇"
BUNDLE_ID="com.chansukim.MemoDolmaeng"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
ICON_SOURCE="$ROOT_DIR/Resources/AppIconSource.png"
FINAL_APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
ASSEMBLY_DIR="$(mktemp -d "${TMPDIR%/}/memodolmaeng-build.XXXXXX")"
CACHE_DIR="$HOME/Library/Caches/MemoDolmaeng/Build"
CACHED_APP_BUNDLE="$CACHE_DIR/$DISPLAY_NAME.app"
PACKAGE_SCRATCH_DIR="$ASSEMBLY_DIR/SwiftPM"
trap 'rm -rf "$ASSEMBLY_DIR"' EXIT
APP_BUNDLE="$ASSEMBLY_DIR/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICONSET_DIR="$ASSEMBLY_DIR/AppIcon.iconset"

case "$MODE" in
  --build-only|build-only|run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

cd "$ROOT_DIR"
# Package from a clean scratch directory outside the iCloud-backed workspace.
# This deliberately avoids reusing .build: Finder/File Provider timestamp
# reconciliation must never let an older executable slip into a new app bundle.
swift build --scratch-path "$PACKAGE_SCRATCH_DIR" --product "$EXECUTABLE_NAME"
BUILD_BINARY="$(swift build --scratch-path "$PACKAGE_SCRATCH_DIR" --show-bin-path)/$EXECUTABLE_NAME"

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "missing app icon source: $ICON_SOURCE" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

mkdir -p "$ICONSET_DIR"
while read -r point_size pixel_size filename; do
  sips -s format png -z "$pixel_size" "$pixel_size" "$ICON_SOURCE" \
    --out "$ICONSET_DIR/$filename" >/dev/null
done <<'ICON_SIZES'
16 16 icon_16x16.png
16 32 icon_16x16@2x.png
32 32 icon_32x32.png
32 64 icon_32x32@2x.png
128 128 icon_128x128.png
128 256 icon_128x128@2x.png
256 256 icon_256x256.png
256 512 icon_256x256@2x.png
512 512 icon_512x512.png
512 1024 icon_512x512@2x.png
ICON_SIZES
iconutil --convert icns "$ICONSET_DIR" --output "$APP_RESOURCES/AppIcon.icns"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Seal the assembled bundle so local verification catches missing/tampered files.
# This remains an ad-hoc development signature; release signing/notarization is separate.
xattr -cr "$APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

# Keep a clean signed staging bundle outside the iCloud-backed workspace, then
# update the one real app bundle in dist without replacing its root directory.
# Preserving that directory prevents File Provider from creating numbered
# conflict copies while still leaving a directly usable app in dist.
mkdir -p "$CACHE_DIR"
rm -rf "$CACHED_APP_BUNDLE"
mv "$APP_BUNDLE" "$CACHED_APP_BUNDLE"
if [[ -L "$FINAL_APP_BUNDLE" ]]; then
  rm "$FINAL_APP_BUNDLE"
elif [[ -e "$FINAL_APP_BUNDLE" && ! -d "$FINAL_APP_BUNDLE" ]]; then
  echo "refusing to replace non-directory dist artifact: $FINAL_APP_BUNDLE" >&2
  exit 1
fi
mkdir -p "$FINAL_APP_BUNDLE"
rsync --archive --delete "$CACHED_APP_BUNDLE/" "$FINAL_APP_BUNDLE/"
APP_BUNDLE="$FINAL_APP_BUNDLE"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"

# File Provider can immediately reattach FinderInfo to the bundle root in an
# iCloud-backed Documents folder. The payload was already signed and strictly
# verified in the cache above, so verify that the copied Contents are byte-for-
# byte identical instead of trying to reseal the File Provider-owned root.
diff -qr "$CACHED_APP_BUNDLE/Contents" "$APP_BUNDLE/Contents" >/dev/null
plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null

# Old iCloud copies can reappear after a delayed File Provider reconciliation.
# Move only the obsolete pre-rename bundles to the recoverable iCloud Trash so
# the server also learns the deletion; never touch the canonical display-name
# bundle above.
LEGACY_TRASH_DIR=""
while IFS= read -r -d '' LEGACY_APP; do
  if [[ -z "$LEGACY_TRASH_DIR" ]]; then
    ICLOUD_TRASH_ROOT="$HOME/Library/Mobile Documents/.Trash"
    if [[ ! -d "$ICLOUD_TRASH_ROOT" ]]; then
      ICLOUD_TRASH_ROOT="$HOME/.Trash"
    fi
    LEGACY_TRASH_DIR="$(mktemp -d "$ICLOUD_TRASH_ROOT/MemoDolmaeng-dist-legacy.XXXXXX")"
  fi
  mv "$LEGACY_APP" "$LEGACY_TRASH_DIR/"
done < <(find "$DIST_DIR" -maxdepth 1 -name 'MemoDolmaeng*.app' -print0)

APP_COUNT="$(find "$DIST_DIR" -maxdepth 1 -name '*.app' -print | wc -l | tr -d ' ')"
if [[ "$APP_COUNT" != "1" ]]; then
  echo "expected exactly one app bundle in dist, found $APP_COUNT" >&2
  exit 1
fi

ensure_not_running() {
  if pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
    echo "$DISPLAY_NAME is already running. Quit it normally before launching this build." >&2
    return 1
  fi
}

open_app() {
  ensure_not_running
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --build-only|build-only)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    ensure_not_running
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$EXECUTABLE_NAME" >/dev/null
    ;;
esac
