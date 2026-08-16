#!/bin/zsh
set -e

echo "🔨 [1/5] Building Release binary with optimizations..."
swift build -c release

DIST_DIR="dist"
APP_BUNDLE="${DIST_DIR}/AnyDiff.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "📦 [2/5] Constructing native macOS App Bundle..."
rm -rf "${DIST_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy binary
cp ".build/release/AnyDiff" "${MACOS_DIR}/AnyDiff"
chmod +x "${MACOS_DIR}/AnyDiff"

# Copy Icons
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi
if [ -f "Resources/AppIcon.png" ]; then
    cp "Resources/AppIcon.png" "${RESOURCES_DIR}/AppIcon.png"
fi


# Create Info.plist
cat << 'PLIST' > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>AnyDiff</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>app.anydiff</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AnyDiff</string>
    <key>CFBundleDisplayName</key>
    <string>AnyDiff</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSRequiresAquaSystemAppearance</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 AnyDiff. All rights reserved.</string>
</dict>
</plist>
PLIST

# Create PkgInfo
echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# Ad-hoc code signing
echo "🔏 [3/5] Ad-hoc code signing AnyDiff.app..."
codesign --force --deep --sign - "${APP_BUNDLE}"

# Create ZIP
echo "🗜️ [4/5] Creating ZIP archive..."
(cd "${DIST_DIR}" && zip -r -q -y "AnyDiff-macOS.zip" "AnyDiff.app")

# Create DMG
echo "💿 [5/5] Creating DMG disk image..."
hdiutil create -volname "AnyDiff" -srcfolder "${APP_BUNDLE}" -ov -format UDZO "${DIST_DIR}/AnyDiff.dmg" > /dev/null

echo "\n✨ Build and packaging complete! Distribution files ready in dist/:"
ls -lh "${DIST_DIR}"
