#!/usr/bin/env bash
set -euo pipefail

# Build CodexGateway macOS menu bar app from the command line.
# Uses Swift Package Manager (SPM) by default.
#
# Usage:
#   ./scripts/build-macos-app.sh
#   ./scripts/build-macos-app.sh --sign "Developer ID Application: Your Name (TEAMID)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

APP_NAME="CodexGateway"
EXECUTABLE_NAME="CodexGateway"
APP_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"

BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"

SIGN_IDENTITY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign)
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --name)
            APP_NAME="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--sign IDENTITY] [--name NAME]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "==> Building ${APP_NAME} macOS app..."

mkdir -p "$DIST_DIR"
mkdir -p "$BUILD_DIR"

if [ ! -f "$ROOT_DIR/Package.swift" ]; then
    echo "ERROR: No Package.swift found."
    exit 1
fi

echo "==> Building with Swift Package Manager..."
swift build -c release --package-path "$ROOT_DIR"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/release/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
# Older CodexBar updaters `ditto` without deleting first, so Launch Services can keep
# launching a stale Contents/MacOS/CodexBar. Ship the new binary under that name too
# so the leftover path runs migration (CodexBar.app → CodexGateway.app).
cp "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/CodexBar"
chmod +x "$APP_BUNDLE/Contents/MacOS/CodexBar"
echo "==> Bundled legacy MacOS/CodexBar executable alias for upgrade launches"

ICONSET_DIR="$ROOT_DIR/CodexGateway/Resources/Assets.xcassets/MenuBarIcon.imageset"

copy_icon() {
    local src="$1"
    local dst="$2"
    if [ -f "$src" ]; then
        cp "$src" "$APP_BUNDLE/Contents/Resources/$dst"
        echo "==> Copied menu bar icon: $(basename "$src") -> $dst"
    fi
}

if [ -f "$ROOT_DIR/MenuBarIcon.png" ]; then
    copy_icon "$ROOT_DIR/MenuBarIcon.png" "MenuBarIcon.png"
elif [ -f "$ICONSET_DIR/MenuBarIcon.png" ]; then
    copy_icon "$ICONSET_DIR/MenuBarIcon.png" "MenuBarIcon.png"
fi

if [ -f "$ROOT_DIR/MenuBarIcon@2x.png" ]; then
    copy_icon "$ROOT_DIR/MenuBarIcon@2x.png" "MenuBarIcon@2x.png"
elif [ -f "$ICONSET_DIR/MenuBarIcon@2x.png" ]; then
    copy_icon "$ICONSET_DIR/MenuBarIcon@2x.png" "MenuBarIcon@2x.png"
fi

if [ -f "$ICONSET_DIR/MenuBarIcon@3x.png" ]; then
    copy_icon "$ICONSET_DIR/MenuBarIcon@3x.png" "MenuBarIcon@3x.png"
fi
if [ -f "$ROOT_DIR/MenuBarIcon@3x.png" ]; then
    copy_icon "$ROOT_DIR/MenuBarIcon@3x.png" "MenuBarIcon@3x.png"
fi

generate_app_icon() {
    local src="$1"
    if [ ! -f "$src" ]; then return; fi
    echo "==> Generating AppIcon.icns from $src"
    local iconset_dir="$BUILD_DIR/AppIcon.iconset"
    rm -rf "$iconset_dir"
    mkdir -p "$iconset_dir"
    sips -z 16 16     "$src" --out "$iconset_dir/icon_16x16.png"     >/dev/null 2>&1 || true
    sips -z 32 32     "$src" --out "$iconset_dir/icon_16x16@2x.png"  >/dev/null 2>&1 || true
    sips -z 32 32     "$src" --out "$iconset_dir/icon_32x32.png"     >/dev/null 2>&1 || true
    sips -z 64 64     "$src" --out "$iconset_dir/icon_32x32@2x.png"  >/dev/null 2>&1 || true
    sips -z 128 128   "$src" --out "$iconset_dir/icon_128x128.png"   >/dev/null 2>&1 || true
    sips -z 256 256   "$src" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null 2>&1 || true
    sips -z 256 256   "$src" --out "$iconset_dir/icon_256x256.png"   >/dev/null 2>&1 || true
    sips -z 512 512   "$src" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null 2>&1 || true
    sips -z 512 512   "$src" --out "$iconset_dir/icon_512x512.png"   >/dev/null 2>&1 || true
    sips -z 1024 1024 "$src" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null 2>&1 || true
    iconutil -c icns "$iconset_dir" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" >/dev/null 2>&1 || true
    rm -rf "$iconset_dir"
}

if [ -f "$ROOT_DIR/AppIcon.png" ]; then
    generate_app_icon "$ROOT_DIR/AppIcon.png"
elif [ -f "$ROOT_DIR/AppIcon1024.png" ]; then
    generate_app_icon "$ROOT_DIR/AppIcon1024.png"
elif [ -f "$ICONSET_DIR/MenuBarIcon@3x.png" ]; then
    echo "==> Using MenuBarIcon as fallback AppIcon (add AppIcon.png in project root for best quality)"
    generate_app_icon "$ICONSET_DIR/MenuBarIcon@3x.png"
fi

INSTALL_HELPER_SRC="$ROOT_DIR/scripts/codexgateway-install-update.sh"
if [ -f "$INSTALL_HELPER_SRC" ]; then
    cp "$INSTALL_HELPER_SRC" "$APP_BUNDLE/Contents/Resources/codexgateway-install-update"
    chmod +x "$APP_BUNDLE/Contents/Resources/codexgateway-install-update"
    echo "==> Bundled in-app update helper"
fi

ICON_FILE=""
if [ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]; then
    ICON_FILE=$'\n    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>'
fi

cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.rimusz.CodexGateway</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>$ICON_FILE
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

chmod +x "$SCRIPT_DIR/codesign-app-bundle.sh"
chmod +x "$SCRIPT_DIR/bundle-cursor-bridge.sh"

"$SCRIPT_DIR/bundle-cursor-bridge.sh" "$APP_BUNDLE/Contents/Resources"

if [ -n "$SIGN_IDENTITY" ]; then
    "$SCRIPT_DIR/codesign-app-bundle.sh" "$APP_BUNDLE" "$SIGN_IDENTITY"
else
    "$SCRIPT_DIR/codesign-app-bundle.sh" "$APP_BUNDLE"
fi

echo "==> App bundle ready: $APP_BUNDLE"

echo "==> Creating DMG..."
DMG_PATH="$DIST_DIR/${APP_NAME}-macOS.dmg"
rm -f "$DMG_PATH"

DMG_STAGING="$DIST_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_STAGING"

echo ""
echo "==> Done!"
echo "   App:  $APP_BUNDLE"
echo "   DMG:  $DMG_PATH"
