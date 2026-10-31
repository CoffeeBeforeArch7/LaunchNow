#!/bin/bash
# Builds LaunchNow with the Command Line Tools only (no Xcode): compiles the
# Swift sources with swiftc, assembles the .app bundle by hand, and signs it
# with your own identity if build.local.sh names one (so Accessibility grants
# survive rebuilds), otherwise ad hoc.
#
#   ./build.sh            build into build/LaunchNow.app
#   ./build.sh --install  also replace /Applications/LaunchNow.app
set -euo pipefail
cd "$(dirname "$0")"

APP=LaunchNow
# Personal settings go in build.local.sh (git-ignored): the bundle id, a signing
# identity and, if that identity sits in its own keychain, the keychain to unlock
# first. Without that file the app gets the default bundle id and an ad-hoc signature.
BUNDLE_ID=io.github.coffeebeforearch7.LaunchNow
IDENTITY=""
SIGNING_KEYCHAIN=""
SIGNING_KEYCHAIN_PASSWORD=""
if [[ -f build.local.sh ]]; then
    source build.local.sh
fi
PBX=LaunchNow.xcodeproj/project.pbxproj
VERSION=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$PBX" | head -1)
BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' "$PBX" | head -1)
OUT="build/$APP.app"

# Prefer the macOS 26 SDK (the app's deployment target): the 27 SDK turns SwiftUI
# property wrappers such as @State into macros whose plugin (SwiftUIMacros) only
# ships with Xcode. Swift 6.4 reads the 26 interfaces given their compiler version.
PINNED_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
SDK_COMPAT_FLAGS=()
if [[ -d "$PINNED_SDK" ]]; then
    SDK=$PINNED_SDK
    SDK_COMPAT_FLAGS=(-Xfrontend -interface-compiler-version -Xfrontend 6.3.2)
else
    SDK=$(xcrun --show-sdk-path)
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "▸ Compiling…"
# Mirrors the Xcode target's Swift settings: Swift 5 mode, MainActor default
# isolation, approachable concurrency and member import visibility.
swiftc -O -target arm64-apple-macos26.0 -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" \
    -swift-version 5 -parse-as-library -module-name "$APP" \
    -default-isolation MainActor \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature MemberImportVisibility \
    LaunchNow/*.swift -o "$OUT/Contents/MacOS/$APP"

echo "▸ Assembling bundle…"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>$APP</string>
    <key>CFBundleExecutable</key><string>$APP</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
cp -R ./*.lproj "$OUT/Contents/Resources/"

# The Icon Composer source (AppIcon.icon) needs Xcode's actool, so build a
# classic .icns from its artwork instead.
WORK=$(mktemp -d)
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
ART="LaunchNow/AppIcon.icon/Assets/未命名 2.png"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$ART" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ART" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"
rm -rf "$WORK"

echo "▸ Signing…"
# A stable identity keeps Accessibility grants across rebuilds. When it lives in
# its own keychain, unlock that first: signing with a locked keychain makes macOS
# pop up a password dialog, so if anything is missing fall back to ad hoc.
IDENTITIES=$(security find-identity -p codesigning 2>/dev/null || true)
if [[ -n "$IDENTITY" && "$IDENTITIES" == *"\"$IDENTITY\""* ]] \
    && { [[ -z "$SIGNING_KEYCHAIN" ]] \
         || security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN" 2>/dev/null; }; then
    codesign --force --sign "$IDENTITY" "$OUT"
else
    if [[ -n "$IDENTITY" ]]; then
        echo "  ⚠ '$IDENTITY' unavailable; signing ad-hoc (Accessibility grants won't survive rebuilds)"
    fi
    codesign --force --sign - "$OUT"
fi
codesign --verify --deep --strict "$OUT"
echo "✓ Built $OUT ($VERSION)"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e "quit app \"$APP\"" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -xq "$APP" || break
        sleep 0.5
    done
    rm -rf "/Applications/$APP.app"
    ditto "$OUT" "/Applications/$APP.app"
    echo "✓ Installed /Applications/$APP.app"
fi
