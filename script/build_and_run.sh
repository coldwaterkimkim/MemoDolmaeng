#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MemoDolmaeng"
BUNDLE_ID="com.chansukim.MemoDolmaeng"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
FINAL_APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ASSEMBLY_DIR="$(mktemp -d "${TMPDIR%/}/memodolmaeng-build.XXXXXX")"
CACHE_DIR="$HOME/Library/Caches/MemoDolmaeng/Build"
CACHED_APP_BUNDLE="$CACHE_DIR/$APP_NAME.app"
trap 'rm -rf "$ASSEMBLY_DIR"' EXIT
APP_BUNDLE="$ASSEMBLY_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

case "$MODE" in
  --build-only|build-only|run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

cd "$ROOT_DIR"
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

mkdir -p "$DIST_DIR"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
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

# Keep the signed target outside the iCloud-backed workspace. File Provider can
# re-add FinderInfo even after signing, which makes later strict verification
# of an otherwise valid bundle fail.
mkdir -p "$CACHE_DIR"
rm -rf "$CACHED_APP_BUNDLE"
mv "$APP_BUNDLE" "$CACHED_APP_BUNDLE"
rm -rf "$FINAL_APP_BUNDLE"
ln -s "$CACHED_APP_BUNDLE" "$FINAL_APP_BUNDLE"
APP_BUNDLE="$FINAL_APP_BUNDLE"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign --verify --deep --strict "$APP_BUNDLE"

ensure_not_running() {
  if pgrep -x "$APP_NAME" >/dev/null; then
    echo "$APP_NAME is already running. Quit it normally before launching this build." >&2
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
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
esac
