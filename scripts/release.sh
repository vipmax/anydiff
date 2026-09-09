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
if [ -n "$(git status --porcelain -uno | grep -v 'CHANGELOG.md\|README.md\|package_app.sh\|\.github\|justfile\|release.sh')" ]; then
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

echo "📦 Packaging AnyDiff.app, ZIP, and DMG..."
./scripts/package_app.sh

DIST_ZIP="dist/AnyDiff-macOS.zip"
DIST_DMG="dist/AnyDiff.dmg"

if [ ! -f "${DIST_ZIP}" ] || [ ! -f "${DIST_DMG}" ]; then
    echo "❌ Error: Missing distribution artifacts in dist/"
    exit 1
fi

# 7. Compute SHA-256 of the exact zip archive
SHA256=$(shasum -a 256 "${DIST_ZIP}" | awk '{print $1}')
echo "🔒 Calculated SHA-256 for ${DIST_ZIP}:"
echo "   ${SHA256}"

# 8. Commit version bump and create git tag
echo "📝 Committing version bump to git..."
git add scripts/package_app.sh README.md CHANGELOG.md .github/workflows/release.yml scripts/release.sh justfile
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

# 10. Create GitHub Release with native assets
echo "☁️ Creating GitHub Release ${TAG}..."
if gh release view "${TAG}" >/dev/null 2>&1; then
    echo "Release ${TAG} already exists on GitHub, updating notes and assets..."
    gh release edit "${TAG}" --title "AnyDiff ${TAG}" --notes-file "${NOTES_TMP}"
    gh release upload "${TAG}" "${DIST_DMG}" "${DIST_ZIP}" --clobber
else
    gh release create "${TAG}" \
        --title "AnyDiff ${TAG}" \
        --notes-file "${NOTES_TMP}" \
        "${DIST_DMG}" \
        "${DIST_ZIP}"
fi
rm -f "${NOTES_TMP}"

# 11. Update Homebrew tap
TAP_DIR="$(brew --repo vipmax/tap 2>/dev/null || true)"
if [ -z "${TAP_DIR}" ] || [ ! -d "${TAP_DIR}" ]; then
    TAP_DIR="/opt/homebrew/Library/Taps/vipmax/homebrew-tap"
fi

if [ -d "${TAP_DIR}" ] && [ -f "${TAP_DIR}/Casks/anydiff.rb" ]; then
    echo "🍺 Updating Homebrew Cask formula in ${TAP_DIR}..."
    sed -i '' -E "s/version \"[^\"]+\"/version \"${VERSION}\"/" "${TAP_DIR}/Casks/anydiff.rb"
    sed -i '' -E "s/sha256 \"[^\"]+\"/sha256 \"${SHA256}\"/" "${TAP_DIR}/Casks/anydiff.rb"

    echo "🍺 Committing and pushing tap update..."
    git -C "${TAP_DIR}" add Casks/anydiff.rb
    git -C "${TAP_DIR}" commit -m "anydiff ${VERSION}"
    git -C "${TAP_DIR}" push origin main
    echo "✅ Homebrew tap successfully updated with SHA-256: ${SHA256}"
else
    echo "⚠️ Warning: Tap directory not found at ${TAP_DIR}. Please update anydiff.rb manually:"
    echo "   version \"${VERSION}\""
    echo "   sha256 \"${SHA256}\""
fi

echo ""
echo "🎉 Release ${TAG} successfully published!"
echo "   - GitHub Release: https://github.com/vipmax/anydiff/releases/tag/${TAG}"
echo "   - SHA-256: ${SHA256}"
echo "   - Homebrew Cask: updated to ${VERSION}"
