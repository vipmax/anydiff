#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

# 1. Parse & validate version argument
TARGET_VERSION="${1:-}"
if [ -z "${TARGET_VERSION}" ]; then
    echo "❌ Error: Version argument is required."
    echo "Usage: $0 <version> (e.g. $0 1.5.0)"
    exit 1
fi

# Strip leading 'v' if present
VERSION="${TARGET_VERSION#v}"
if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ Error: Version must follow Semantic Versioning (e.g., 1.5.0). Got: ${TARGET_VERSION}"
    exit 1
fi

TAG="v${VERSION}"
echo "🚀 Preparing release ${TAG}..."

# 2. Check for unstaged/uncommitted changes (ignoring release-related files)
if [ -n "$(git status --porcelain -uno | grep -v 'CHANGELOG.md\|README.md\|package_app.sh\|install.sh\|\.github\|justfile\|release.sh')" ]; then
    echo "❌ Error: Working tree has unstaged changes. Please commit or stash them first."
    git status -s
    exit 1
fi

# 3. Verify CHANGELOG.md entry exists
if ! grep -q "^## \[${VERSION}\]" CHANGELOG.md; then
    echo "❌ Error: CHANGELOG.md does not contain an entry for ## [${VERSION}]."
    echo "Please add release notes for ${VERSION} in CHANGELOG.md before releasing."
    exit 1
fi

# 4. Extract release notes from CHANGELOG.md
NOTES_TMP=$(mktemp)
awk "/^## \[${VERSION}\]/{flag=1; next} /^## \[/{flag=0} flag" CHANGELOG.md > "${NOTES_TMP}"

if [ ! -s "${NOTES_TMP}" ]; then
    echo "⚠️ Warning: Release notes for ${VERSION} are empty in CHANGELOG.md. Using fallback notes."
    echo "AnyDiff release ${TAG}" > "${NOTES_TMP}"
fi

# 5. Read and increment build number in scripts/package_app.sh
CURRENT_BUILD=$(grep -A 1 "CFBundleVersion" scripts/package_app.sh | grep "<string>" | sed -E 's/.*<string>([0-9]+)<\/string>.*/\1/')
if [ -z "${CURRENT_BUILD}" ]; then
    CURRENT_BUILD="1"
fi
NEW_BUILD=$((CURRENT_BUILD + 1))
echo "📌 Bumping version to ${VERSION} (Build ${NEW_BUILD})..."

# Update scripts/package_app.sh
sed -i '' -E "/CFBundleShortVersionString/{n;s|<string>[^<]+</string>|<string>${VERSION}</string>|;}" scripts/package_app.sh
sed -i '' -E "/CFBundleVersion/{n;s|<string>[^<]+</string>|<string>${NEW_BUILD}</string>|;}" scripts/package_app.sh

# Update README.md release download links
sed -i '' -E "s|releases/download/v[0-9]+\.[0-9]+\.[0-9]+/|releases/download/${TAG}/|g" README.md

# 6. Run release tests and packaging
echo "🧪 Running check (release build & unit test suite)..."
just check

echo "📦 Packaging AnyDiff.app, ZIP, and DMG for all architectures (arm64 & x86_64)..."
./scripts/package_app.sh all

DIST_ARM64_ZIP="dist/AnyDiff-macOS-arm64.zip"
DIST_ARM64_DMG="dist/AnyDiff-macOS-arm64.dmg"
DIST_X86_ZIP="dist/AnyDiff-macOS-x86_64.zip"
DIST_X86_DMG="dist/AnyDiff-macOS-x86_64.dmg"
DIST_LEGACY_ZIP="dist/AnyDiff-macOS.zip"
DIST_LEGACY_DMG="dist/AnyDiff.dmg"

for dist_file in "${DIST_ARM64_ZIP}" "${DIST_ARM64_DMG}" "${DIST_X86_ZIP}" "${DIST_X86_DMG}"; do
    if [ ! -f "${dist_file}" ]; then
        echo "❌ Error: Missing distribution artifact: ${dist_file}"
        exit 1
    fi
done

# 7. Compute SHA-256 of the zip archives for both architectures
SHA256_ARM64=$(shasum -a 256 "${DIST_ARM64_ZIP}" | awk '{print $1}')
SHA256_X86_64=$(shasum -a 256 "${DIST_X86_ZIP}" | awk '{print $1}')
echo "🔒 Calculated SHA-256 for arm64 (${DIST_ARM64_ZIP}):"
echo "   ${SHA256_ARM64}"
echo "🔒 Calculated SHA-256 for x86_64 (${DIST_X86_ZIP}):"
echo "   ${SHA256_X86_64}"

# 8. Commit version bump and create git tag
echo "📝 Committing version bump to git..."
git add scripts/package_app.sh scripts/release.sh scripts/install.sh README.md CHANGELOG.md .github/workflows/release.yml justfile
git commit -m "chore(release): bump version to ${TAG}" || true

if git rev-parse "${TAG}" >/dev/null 2>&1; then
    echo "⚠️ Tag ${TAG} already exists locally. Updating tag..."
    git tag -d "${TAG}"
fi
git tag -a "${TAG}" -m "Release ${TAG}"

# 9. Push git branch and tag to origin
echo "⬆️ Pushing commits and tag to origin..."
git push origin main
git push origin "${TAG}" --force

# 10. Create GitHub Release with native assets (both architectures + legacy aliases)
RELEASE_ASSETS=(
    "${DIST_ARM64_DMG}"
    "${DIST_ARM64_ZIP}"
    "${DIST_X86_DMG}"
    "${DIST_X86_ZIP}"
    "${DIST_LEGACY_DMG}"
    "${DIST_LEGACY_ZIP}"
)

echo "☁️ Creating GitHub Release ${TAG}..."
if gh release view "${TAG}" >/dev/null 2>&1; then
    echo "Release ${TAG} already exists on GitHub, updating notes and assets..."
    gh release edit "${TAG}" --title "AnyDiff ${TAG}" --notes-file "${NOTES_TMP}"
    gh release upload "${TAG}" "${RELEASE_ASSETS[@]}" --clobber
else
    gh release create "${TAG}" \
        --title "AnyDiff ${TAG}" \
        --notes-file "${NOTES_TMP}" \
        "${RELEASE_ASSETS[@]}"
fi
rm -f "${NOTES_TMP}"

# 11. Update Homebrew tap
TAP_DIR="$(brew --repo vipmax/tap 2>/dev/null || true)"
if [ -z "${TAP_DIR}" ] || [ ! -d "${TAP_DIR}" ]; then
    TAP_DIR="/opt/homebrew/Library/Taps/vipmax/homebrew-tap"
fi

if [ -d "${TAP_DIR}" ] && [ -f "${TAP_DIR}/Casks/anydiff.rb" ]; then
    echo "🍺 Updating Homebrew Cask formula in ${TAP_DIR} with multi-arch support..."
    cat << CASK > "${TAP_DIR}/Casks/anydiff.rb"
cask "anydiff" do
  arch arm: "arm64", intel: "x86_64"

  version "${VERSION}"
  sha256 arm:   "${SHA256_ARM64}",
         intel: "${SHA256_X86_64}"

  url "https://github.com/vipmax/anydiff/releases/download/v#{version}/AnyDiff-macOS-#{arch}.zip"
  name "AnyDiff"
  desc "High-performance native macOS MultiBuffer Diff editor with embedded AI agent"
  homepage "https://github.com/vipmax/anydiff"

  depends_on macos: :ventura

  app "AnyDiff.app"
  binary "#{appdir}/AnyDiff.app/Contents/MacOS/AnyDiff", target: "anydiff"

  zap trash: [
    "~/Library/Saved Application State/app.anydiff.savedState",
  ]
end
CASK

    echo "🍺 Committing and pushing tap update..."
    git -C "${TAP_DIR}" add Casks/anydiff.rb
    git -C "${TAP_DIR}" commit -m "anydiff ${VERSION}"
    git -C "${TAP_DIR}" push origin main
    echo "✅ Homebrew tap successfully updated with arm64 and x86_64 SHA-256 values!"
else
    echo "⚠️ Warning: Tap directory not found at ${TAP_DIR}. Please update anydiff.rb manually:"
    echo "   version \"${VERSION}\""
    echo "   sha256 arm: \"${SHA256_ARM64}\", intel: \"${SHA256_X86_64}\""
fi

echo ""
echo "🎉 Release ${TAG} successfully published!"
echo "   - GitHub Release: https://github.com/vipmax/anydiff/releases/tag/${TAG}"
echo "   - Apple Silicon SHA-256: ${SHA256_ARM64}"
echo "   - Intel SHA-256:         ${SHA256_X86_64}"
echo "   - Homebrew Cask: updated to ${VERSION} (multi-arch)"
