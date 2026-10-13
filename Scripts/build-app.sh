#!/usr/bin/env bash
# Build SparkWatch.app (menu bar accessory) from SwiftPM output.
#
# SwiftPM only, no Xcode project — mirrors the macfan build so the two apps on
# this Mac are packaged the same way. Ad-hoc signature: Gatekeeper will complain
# on first launch, and the fix is `xattr -dr com.apple.quarantine <app>` (the
# recursive variant matters — the quarantine bit is also on the inner binary).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="SparkWatch"
BUNDLE_ID="com.yingzi.sparkwatch"
# Overridable so a release workflow can stamp the tag's version into the bundle:
# the published DMG must not be named one version while the app inside says
# another. Falls back to the development version for local builds.
VERSION="${VERSION:-0.3.0}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
# The icon is a committed asset (Assets/AppIcon.icns) rather than something every
# build draws: the drawing script needs Pillow, and a release runner should not
# depend on a Python imaging library to produce the artifact. Locally it still
# redraws when the script is newer, so iterating on the art stays automatic —
# guarded by an import check, because on a machine without Pillow the committed
# asset is the right answer and an ImportError is not.
ICNS="$ROOT/Assets/AppIcon.icns"
if [ -f "$ICNS" ]     && python3 -c 'import PIL' 2>/dev/null     && [ "$(find "$ROOT/Scripts/make-icon.py" -newer "$ICNS" 2>/dev/null)" != "" ]; then
    echo "==> icon (make-icon.py is newer, redrawing)"
    python3 "$ROOT/Scripts/make-icon.py" "$ROOT/Assets" >/dev/null
fi
if [ ! -f "$ICNS" ]; then
    echo "==> icon (no committed asset, generating)"
    python3 "$ROOT/Scripts/make-icon.py" "$ROOT/Assets" >/dev/null
fi
echo "==> icon: $ICNS"

echo "==> release build"
swift build -c release --product "$APP_NAME"

echo "==> assemble bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Accessory app: menu bar only, no Dock icon, no main window. Launchpad
         and Finder still show it (and its icon) from /Applications. -->
    <key>LSUIElement</key><true/>
    <!-- Inference endpoints on a private tailnet are plain HTTP (http://100.x:18300),
         and App Transport Security otherwise refuses them with NSURLErrorDomain -1022.
         Scoped exception: this app only talks to machines the user configured. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
    <key>NSLocalNetworkUsageDescription</key>
    <string>SparkWatch reads GPU and inference metrics from the DGX boxes you configured.</string>
    <key>NSHumanReadableCopyright</key><string>MIT. Incorporates MIT-licensed code, see THIRD_PARTY_NOTICES.md.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> sign (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null
codesign --verify --verbose "$APP" 2>&1 | tail -2

# Keep the build output out of Spotlight/Launchpad: an app bundle sitting in the
# repo would otherwise show up as a second SparkWatch (and "open" could pick it).
touch "$DIST/.metadata_never_index" 2>/dev/null || true
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true

echo "==> built: $APP"
