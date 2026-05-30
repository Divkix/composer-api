#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/API for Cursor.app}"
DIST_DIR="$(dirname "$APP_PATH")"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST")"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
DMG_BASENAME="${CURSOR_API_DMG_BASENAME:-API-for-Cursor-${APP_VERSION}-${APP_BUILD}}"
DMG_PATH="$DIST_DIR/$DMG_BASENAME.dmg"
LATEST_DMG_PATH="$DIST_DIR/API-for-Cursor-latest.dmg"
VOLUME_NAME="${CURSOR_API_DMG_VOLUME_NAME:-$APP_NAME}"
CODE_SIGN_IDENTITY="${CURSOR_API_CODE_SIGN_IDENTITY:-}"
BACKGROUND_SOURCE="${CURSOR_API_DMG_BACKGROUND:-$ROOT_DIR/Resources/dmg-background.png}"
BACKGROUND_NAME="dmg-background.png"
BACKGROUND_WIDTH=720
BACKGROUND_HEIGHT=432
DMG_ICON_SIZE=96
PYTHON_DEPS_DIR=""

fail() {
  echo "DMG creation failed: $*" >&2
  exit 1
}

[ -d "$APP_PATH" ] || fail "app bundle is missing at $APP_PATH"
[ -f "$INFO_PLIST" ] || fail "Info.plist is missing at $INFO_PLIST"
[ -s "$BACKGROUND_SOURCE" ] || fail "DMG background is missing at $BACKGROUND_SOURCE"
command -v hdiutil >/dev/null 2>&1 || fail "hdiutil is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

ensure_dmg_layout_python_deps() {
  if python3 - <<'PY' >/dev/null 2>&1
import ds_store
import mac_alias
PY
  then
    return
  fi

  PYTHON_DEPS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-dmg-python.XXXXXX")"
  PIP_DISABLE_PIP_VERSION_CHECK=1 python3 -m pip install \
    --quiet \
    --no-input \
    --target "$PYTHON_DEPS_DIR" \
    ds_store==1.3.2 \
    mac_alias==2.2.3 >&2
  export PYTHONPATH="$PYTHON_DEPS_DIR${PYTHONPATH:+:$PYTHONPATH}"
}

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-dmg.XXXXXX")"
TEMP_DMG="$DIST_DIR/$DMG_BASENAME.rw.dmg"
MOUNT_DIR=""
cleanup() {
  if [ -n "$MOUNT_DIR" ]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  rm -rf "$STAGING_DIR" "$TEMP_DMG" "$MOUNT_DIR" "$PYTHON_DEPS_DIR"
}
trap cleanup EXIT

cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p "$STAGING_DIR/.background"
cp "$BACKGROUND_SOURCE" "$STAGING_DIR/.background/$BACKGROUND_NAME"
chflags hidden "$STAGING_DIR/.background" 2>/dev/null || true
ensure_dmg_layout_python_deps

rm -f "$DMG_PATH" "$LATEST_DMG_PATH" "$TEMP_DMG"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$TEMP_DMG" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach "$TEMP_DMG" \
  -readwrite \
  -noverify \
  -noautoopen \
  -plist)"
MOUNT_DIR="$(printf '%s' "$ATTACH_OUTPUT" | python3 -c 'import plistlib, sys
plist = plistlib.loads(sys.stdin.buffer.read())
for entity in plist.get("system-entities", []):
    mount_point = entity.get("mount-point")
    if mount_point:
        print(mount_point)
        break
')"
[ -d "$MOUNT_DIR" ] || fail "could not determine mounted DMG path"

python3 - \
  "$MOUNT_DIR" \
  "$APP_NAME.app" \
  "$BACKGROUND_NAME" \
  "$BACKGROUND_WIDTH" \
  "$BACKGROUND_HEIGHT" \
  "$DMG_ICON_SIZE" <<'PY'
from pathlib import Path
import sys

from ds_store import DSStore
from mac_alias import Alias

mount_dir = Path(sys.argv[1])
app_item_name = sys.argv[2]
background_name = sys.argv[3]
window_width = int(sys.argv[4])
window_height = int(sys.argv[5])
icon_size = int(sys.argv[6])

background_path = mount_dir / ".background" / background_name
store_path = mount_dir / ".DS_Store"
background_alias = Alias.for_file(str(background_path)).to_bytes()

with DSStore.open(str(store_path), "w+") as store:
    store["."]["bwsp"] = {
        "ContainerShowSidebar": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
        "ShowStatusBar": False,
        "ShowTabView": False,
        "ShowToolbar": False,
        "SidebarWidth": 0,
        "WindowBounds": f"{{{{120, 120}}, {{{window_width}, {window_height}}}}}",
    }
    store["."]["icvp"] = {
        "arrangeBy": "none",
        "backgroundColorBlue": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorRed": 1.0,
        "backgroundImageAlias": background_alias,
        "backgroundType": 2,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "iconSize": float(icon_size),
        "labelOnBottom": True,
        "showIconPreview": True,
        "showItemInfo": False,
        "textSize": 12.0,
        "viewOptionsVersion": 1,
    }
    store["."]["vSrn"] = ("long", 1)
    store[app_item_name]["Iloc"] = (180, 216)
    store["Applications"]["Iloc"] = (540, 216)
    store[".background"]["Iloc"] = (1000, 1000)
    store[".DS_Store"]["Iloc"] = (1100, 1000)
PY

SetFile -a V "$MOUNT_DIR/.background" 2>/dev/null || chflags hidden "$MOUNT_DIR/.background" 2>/dev/null || true

sync
hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNT_DIR=""

hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null

if [ -n "$CODE_SIGN_IDENTITY" ] && [ "$CODE_SIGN_IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$CODE_SIGN_IDENTITY" "$DMG_PATH" >/dev/null
fi

hdiutil verify "$DMG_PATH" >/dev/null
cp "$DMG_PATH" "$LATEST_DMG_PATH"

echo "$DMG_PATH"
