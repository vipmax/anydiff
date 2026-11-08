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
echo "🚀 Preparing release ${TAG} (GitHub Actions build)..."

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

# 6. Commit version bump and create git tag
echo "📝 Committing version bump to git..."
git add scripts/package_app.sh scripts/release.sh scripts/install.sh README.md CHANGELOG.md .github/workflows/release.yml justfile
git commit -m "chore(release): bump version to ${TAG}" || true

if git rev-parse "${TAG}" >/dev/null 2>&1; then
    echo "⚠️ Tag ${TAG} already exists locally. Updating tag..."
    git tag -d "${TAG}"
fi
git tag -a "${TAG}" -m "Release ${TAG}"

# 7. Push git branch and tag to origin to trigger GitHub Actions
echo "⬆️ Pushing commits and tag to origin..."
git push origin main
git push origin "${TAG}" --force

# 8. Create GitHub Release with release notes (assets will be uploaded by GitHub Actions)
echo "☁️ Setting up GitHub Release ${TAG} notes..."
if gh release view "${TAG}" >/dev/null 2>&1; then
    gh release edit "${TAG}" --title "AnyDiff ${TAG}" --notes-file "${NOTES_TMP}"
else
    gh release create "${TAG}" --title "AnyDiff ${TAG}" --notes-file "${NOTES_TMP}"
fi
rm -f "${NOTES_TMP}"

# 9. Wait for GitHub Actions release build to complete
echo "⏳ Waiting for GitHub Actions release workflow to finish building..."
sleep 5
RUN_ID=$(gh run list --workflow="Release AnyDiff" --branch="${TAG}" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
if [ -n "${RUN_ID}" ]; then
    gh run watch "${RUN_ID}"
else
    echo "Waiting for assets to appear on GitHub Release..."
    until gh release view "${TAG}" --json assets -q '.assets.[].name' 2>/dev/null | grep -q "AnyDiff-macOS-arm64.zip"; do
        sleep 5
    done
fi

# 10. Fetch release archives from GitHub Release and compute SHA-256 for Homebrew
echo "⬇️ Downloading CI release archives to compute SHA-256..."
TMP_DIR=$(mktemp -d)
gh release download "${TAG}" -p "AnyDiff-macOS-*.zip" -D "${TMP_DIR}"

SHA256_ARM64=$(shasum -a 256 "${TMP_DIR}/AnyDiff-macOS-arm64.zip" | awk '{print $1}')
SHA256_X86_64=$(shasum -a 256 "${TMP_DIR}/AnyDiff-macOS-x86_64.zip" | awk '{print $1}')
rm -rf "${TMP_DIR}"

echo "🔒 Calculated SHA-256 for arm64 (CI build):"
echo "   ${SHA256_ARM64}"
echo "🔒 Calculated SHA-256 for x86_64 (CI build):"
echo "   ${SHA256_X86_64}"

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

  # The app is ad-hoc signed (not notarized), so Gatekeeper would block the
  # quarantine flag Homebrew adds to downloads. Clear it after every install.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/AnyDiff.app"]
  end

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
echo "🎉 Release ${TAG} successfully published via GitHub Actions!"
echo "   - GitHub Release: https://github.com/vipmax/anydiff/releases/tag/${TAG}"
echo "   - Apple Silicon SHA-256: ${SHA256_ARM64}"
echo "   - Intel SHA-256:         ${SHA256_X86_64}"
echo "   - Homebrew Cask: updated to ${VERSION} (multi-arch)"
