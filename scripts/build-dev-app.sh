#!/usr/bin/env bash
set -euo pipefail

# Build a lightweight CodexGateway.app bundle for local development.
# Uses the same bundle identifier as the packaged app.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexGateway"
EXECUTABLE_NAME="CodexGateway"
APP_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
BUILD_DIR="$ROOT_DIR/.build"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
BINARY_DIR="$BUILD_DIR/$BUILD_CONFIG"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"

if [ ! -x "$BINARY_DIR/$EXECUTABLE_NAME" ]; then
    echo "Missing $BUILD_CONFIG binary at $BINARY_DIR/$EXECUTABLE_NAME. Run 'make build' or 'make build-debug' first." >&2
    exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY_DIR/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
# Same dual-exec alias as build-macos-app.sh — needed when testing upgrades into CodexBar.app.
cp "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/CodexBar"
chmod +x "$APP_BUNDLE/Contents/MacOS/CodexBar"

ICONSET_DIR="$ROOT_DIR/CodexGateway/Resources/Assets.xcassets/MenuBarIcon.imageset"
for icon in MenuBarIcon.png MenuBarIcon@2x.png MenuBarIcon@3x.png; do
    if [ -f "$ICONSET_DIR/$icon" ]; then
        cp "$ICONSET_DIR/$icon" "$APP_BUNDLE/Contents/Resources/$icon"
    fi
done

if [ -f "$ROOT_DIR/AppIcon.png" ]; then
    cp "$ROOT_DIR/AppIcon.png" "$APP_BUNDLE/Contents/Resources/AppIcon.png"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$SCRIPT_DIR/codesign-app-bundle.sh"
chmod +x "$SCRIPT_DIR/bundle-cursor-bridge.sh"

"$SCRIPT_DIR/bundle-cursor-bridge.sh" "$APP_BUNDLE/Contents/Resources"

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

"$SCRIPT_DIR/codesign-app-bundle.sh" "$APP_BUNDLE"
echo "Dev app ready: $APP_BUNDLE"
