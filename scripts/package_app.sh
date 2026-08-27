#!/bin/zsh
set -e

echo "🔨 [1/5] Building Release binary with extreme size optimizations..."
swift build -c release \
    -Xswiftc -Osize \
    -Xlinker -dead_strip \
    -Xlinker -exported_symbol -Xlinker _main \
    -Xswiftc -Xfrontend -Xswiftc -disable-reflection-names

DIST_DIR="dist"
APP_BUNDLE="${DIST_DIR}/AnyDiff.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "📦 [2/5] Constructing native macOS App Bundle..."
rm -rf "${DIST_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy binary & strip symbols for minimal release size
cp ".build/release/AnyDiff" "${MACOS_DIR}/AnyDiff"
chmod +x "${MACOS_DIR}/AnyDiff"
echo "✂️ [2.5/5] Stripping debug and unexported symbols..."
strip -u -r "${MACOS_DIR}/AnyDiff"

# Copy Icons (AppIcon.icns includes all resolutions up to 1024x1024)
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
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
    <string>1.0.1</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSRequiresAquaSystemAppearance</key>
    <false/>
    <key>NSSupportsAppNap</key>
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

# Create ZIP with maximum compression
echo "🗜️ [4/5] Creating ZIP archive with maximum compression..."
(cd "${DIST_DIR}" && zip -9 -r -q -y "AnyDiff-macOS.zip" "AnyDiff.app")

# Create DMG with maximum compression
echo "💿 [5/5] Creating DMG disk image with maximum compression..."
hdiutil create -volname "AnyDiff" -srcfolder "${APP_BUNDLE}" -ov -format UDZO -imagekey zlib-level=9 "${DIST_DIR}/AnyDiff.dmg" > /dev/null

echo "\n✨ Build and packaging complete! Distribution files ready in dist/:"
ls -lh "${DIST_DIR}"
