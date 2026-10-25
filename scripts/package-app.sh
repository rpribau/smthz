#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
case "$CONFIG" in
  debug|release) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
SCRATCH="${SMTHZ_SCRATCH_PATH:-.build-lunaapp}"
swift build --configuration "$CONFIG" --scratch-path "$SCRATCH" --product SmthzApp
BUILD_CONFIG="$CONFIG"

APP="$ROOT/build/smthz.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$SCRATCH/$BUILD_CONFIG/SmthzApp" "$MACOS/smthz"

ICON_TMP="$(mktemp -d "${TMPDIR:-/tmp}/smthz-icon.XXXXXX")"
ICONSET="$ICON_TMP/icon.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$ICON_TMP"' EXIT

# Fallback icon: a complete iconset from the source PNG without touching icon/.
for spec in '16 16' '16 32' '32 32' '32 64' '128 128' '128 256' '256 256' '256 512' '512 512' '512 1024'; do
  read -r points pixels <<< "$spec"
  if [[ "$pixels" == "$points" ]]; then suffix=""; else suffix="@2x"; fi
  sips -s format png -z "$pixels" "$pixels" icon/icon.png --out "$ICONSET/icon_${points}x${points}${suffix}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/smthz.icns"

# Liquid Glass icon: compile the Icon Composer document (assets/AppIcon/smthz.icon,
# see docs/ICON.md) into Assets.car plus a generated smthz.icns. If actool fails,
# the iconutil .icns above stays as the only icon.
LIQUID_GLASS_ICON=0
ACTOOL_OUT="$ICON_TMP/actool"
mkdir -p "$ACTOOL_OUT"
if [[ -d assets/AppIcon/smthz.icon ]] && "$DEVELOPER_DIR/usr/bin/actool" assets/AppIcon/smthz.icon \
    --compile "$ACTOOL_OUT" \
    --output-format human-readable-text --notices --warnings --errors \
    --output-partial-info-plist "$ACTOOL_OUT/partial.plist" \
    --app-icon smthz --include-all-app-icons \
    --enable-on-demand-resources NO --development-region en \
    --target-device mac --platform macosx --minimum-deployment-target 26.0 \
    > "$ICON_TMP/actool.log" 2>&1 \
  && [[ -f "$ACTOOL_OUT/Assets.car" ]]; then
  cp "$ACTOOL_OUT/Assets.car" "$RESOURCES/Assets.car"
  if [[ -f "$ACTOOL_OUT/smthz.icns" ]]; then
    cp "$ACTOOL_OUT/smthz.icns" "$RESOURCES/smthz.icns"
  fi
  LIQUID_GLASS_ICON=1
else
  echo "warning: actool could not compile assets/AppIcon/smthz.icon; using the iconutil .icns fallback" >&2
  cat "$ICON_TMP/actool.log" >&2 || true
fi

# Bundled UI fonts (Geist) and Lucide icons, loaded at runtime from Contents/Resources.
if [[ -d Sources/SmthzApp/Resources ]]; then
  cp -R Sources/SmthzApp/Resources/. "$RESOURCES/"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>smthz</string>
  <key>CFBundleIdentifier</key><string>dev.smthz.app</string>
  <key>CFBundleName</key><string>smthz</string>
  <key>CFBundleDisplayName</key><string>smthz</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleIconFile</key><string>smthz</string>
</dict>
</plist>
PLIST
if [[ "$LIQUID_GLASS_ICON" == 1 ]]; then
  # Liquid Glass lookup uses CFBundleIconName (Assets.car); CFBundleIconFile is the fallback.
  plutil -insert CFBundleIconName -string smthz "$CONTENTS/Info.plist"
fi

codesign --force --deep --sign - "$APP"
echo "Created $APP ($CONFIG)"
