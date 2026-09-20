#!/bin/zsh
set -e

# Target architecture: arm64, x86_64 (or intel), or all (default)
TARGET_ARCH="${1:-all}"
DIST_DIR="dist"

package_single_arch() {
    local ARCH="$1"
    local TRIPLE="${ARCH}-apple-macosx"

    echo "\n🔨 [1/5] Building Release binary for ${ARCH} (${TRIPLE}) with extreme size optimizations..."
    swift build -c release --triple "${TRIPLE}" \
        -Xswiftc -Osize \
        -Xlinker -dead_strip \
        -Xlinker -exported_symbol -Xlinker _main \
        -Xswiftc -Xfrontend -Xswiftc -disable-reflection-names

    local ARCH_DIST="${DIST_DIR}/${ARCH}"
    local ARCH_APP_BUNDLE="${ARCH_DIST}/AnyDiff.app"
    local ARCH_CONTENTS_DIR="${ARCH_APP_BUNDLE}/Contents"
    local ARCH_MACOS_DIR="${ARCH_CONTENTS_DIR}/MacOS"
    local ARCH_RESOURCES_DIR="${ARCH_CONTENTS_DIR}/Resources"

    echo "📦 [2/5] Constructing native macOS App Bundle for ${ARCH}..."
    rm -rf "${ARCH_DIST}"
    mkdir -p "${ARCH_MACOS_DIR}"
    mkdir -p "${ARCH_RESOURCES_DIR}"

    # Copy binary & strip symbols for minimal release size
    local BINARY_SRC=".build/${TRIPLE}/release/AnyDiff"
    if [ ! -f "$BINARY_SRC" ]; then
        BINARY_SRC=".build/${ARCH}-apple-macosx/release/AnyDiff"
    fi
    if [ ! -f "$BINARY_SRC" ]; then
        BINARY_SRC=".build/release/AnyDiff"
    fi
    if [ ! -f "$BINARY_SRC" ]; then
        BINARY_SRC=".build/out/Products/Release/AnyDiff"
    fi

    cp "$BINARY_SRC" "${ARCH_MACOS_DIR}/AnyDiff"
    chmod +x "${ARCH_MACOS_DIR}/AnyDiff"
    echo "✂️ [2.5/5] Stripping debug and unexported symbols (${ARCH})..."
    strip -u -r "${ARCH_MACOS_DIR}/AnyDiff"

    # Copy Icons (AppIcon.icns includes all resolutions up to 1024x1024)
    if [ -f "Resources/AppIcon.icns" ]; then
        cp "Resources/AppIcon.icns" "${ARCH_RESOURCES_DIR}/AppIcon.icns"
    fi

    # Copy SwiftPM resource bundles (e.g., AnyDiff_AnyDiffUI.bundle)
    for bundle_dir in .build/${TRIPLE}/release/*.bundle(N) .build/release/*.bundle(N) .build/out/Products/Release/*.bundle(N); do
        if [ -d "$bundle_dir" ] && [ ! -d "${ARCH_RESOURCES_DIR}/$(basename "$bundle_dir")" ]; then
            bundle_name="$(basename "$bundle_dir")"
            echo "📦 Copying resource bundle: $bundle_name"
            cp -R "$bundle_dir" "${ARCH_RESOURCES_DIR}/$bundle_name"
        fi
    done

    # Create Info.plist
    cat << 'PLIST' > "${ARCH_CONTENTS_DIR}/Info.plist"
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
    <string>1.6.0</string>
    <key>CFBundleVersion</key>
    <string>12</string>
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
    echo -n "APPL????" > "${ARCH_CONTENTS_DIR}/PkgInfo"

    # Ad-hoc code signing
    echo "🔏 [3/5] Ad-hoc code signing AnyDiff.app (${ARCH})..."
    codesign --force --deep --sign - "${ARCH_APP_BUNDLE}"

    # Create ZIP with maximum compression
    echo "🗜️ [4/5] Creating ZIP archive with maximum compression (${ARCH})..."
    (cd "${ARCH_DIST}" && zip -9 -r -q -y "../AnyDiff-macOS-${ARCH}.zip" "AnyDiff.app")

    # Create DMG with maximum compression and standard Applications drop-link
    echo "💿 [5/5] Creating DMG disk image with Applications drop-link (${ARCH})..."
    local DMG_STAGING="${ARCH_DIST}/dmg_staging"
    rm -rf "${DMG_STAGING}"
    mkdir -p "${DMG_STAGING}"
    cp -R "${ARCH_APP_BUNDLE}" "${DMG_STAGING}/AnyDiff.app"
    ln -s /Applications "${DMG_STAGING}/Applications"

    hdiutil create \
        -volname "AnyDiff" \
        -srcfolder "${DMG_STAGING}" \
        -ov -format UDZO \
        -imagekey zlib-level=9 \
        "${DIST_DIR}/AnyDiff-macOS-${ARCH}.dmg" > /dev/null

    rm -rf "${DMG_STAGING}"
}

mkdir -p "${DIST_DIR}"

if [ "${TARGET_ARCH}" = "arm64" ]; then
    package_single_arch "arm64"
    rm -rf "${DIST_DIR}/AnyDiff.app"
    cp -R "${DIST_DIR}/arm64/AnyDiff.app" "${DIST_DIR}/AnyDiff.app"
    cp "${DIST_DIR}/AnyDiff-macOS-arm64.zip" "${DIST_DIR}/AnyDiff-macOS.zip"
    cp "${DIST_DIR}/AnyDiff-macOS-arm64.dmg" "${DIST_DIR}/AnyDiff.dmg"
elif [ "${TARGET_ARCH}" = "x86_64" ] || [ "${TARGET_ARCH}" = "intel" ]; then
    package_single_arch "x86_64"
elif [ "${TARGET_ARCH}" = "all" ]; then
    package_single_arch "arm64"
    package_single_arch "x86_64"
    # Backwards compatibility copies and top-level AnyDiff.app
    rm -rf "${DIST_DIR}/AnyDiff.app"
    cp -R "${DIST_DIR}/arm64/AnyDiff.app" "${DIST_DIR}/AnyDiff.app"
    cp "${DIST_DIR}/AnyDiff-macOS-arm64.zip" "${DIST_DIR}/AnyDiff-macOS.zip"
    cp "${DIST_DIR}/AnyDiff-macOS-arm64.dmg" "${DIST_DIR}/AnyDiff.dmg"
else
    echo "❌ Error: Unknown architecture '${TARGET_ARCH}'. Valid options: arm64, x86_64, all"
    exit 1
fi

echo "\n✨ Packaging complete! Distribution files ready in dist/:"
ls -lh "${DIST_DIR}"/*.dmg "${DIST_DIR}"/*.zip
