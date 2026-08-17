#!/bin/bash
set -e

# ==============================================================================
# AnyDiff One-Line Installer for macOS
# ==============================================================================

REPO="vipmax/anydiff"
APP_NAME="AnyDiff.app"
ZIP_NAME="AnyDiff-macOS.zip"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo ""
echo -e "${PURPLE}${BOLD}⚡ AnyDiff Installer${NC}"
echo -e "${CYAN}High-Performance MultiBuffer Diff Editor for macOS${NC}"
echo "--------------------------------------------------------"

# 1. OS Check
OS="$(uname -s)"
if [ "$OS" != "Darwin" ]; then
    echo -e "${RED}❌ Error: AnyDiff is a native macOS application.${NC}"
    echo "Detected OS: $OS. Exiting."
    exit 1
fi

# 2. Determine Install Destination
if [ -w "/Applications" ]; then
    INSTALL_DIR="/Applications"
else
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
fi
APP_PATH="$INSTALL_DIR/$APP_NAME"

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ZIP_PATH="$TMP_DIR/$ZIP_NAME"

# 3. Download Release
echo -e "📥 [1/4] Downloading latest AnyDiff release..."

DOWNLOAD_SUCCESS=false

# Method A: Use GitHub CLI if available and authenticated (perfect for private repos)
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    echo -e "   ${BLUE}→ Using authenticated GitHub CLI...${NC}"
    if gh release download -R "$REPO" -p "$ZIP_NAME" -D "$TMP_DIR" --clobber >/dev/null 2>&1; then
        DOWNLOAD_SUCCESS=true
    fi
fi

# Method B: Use GITHUB_TOKEN if present
if [ "$DOWNLOAD_SUCCESS" = false ] && [ -n "$GITHUB_TOKEN" ]; then
    echo -e "   ${BLUE}→ Using GITHUB_TOKEN authorization...${NC}"
    LATEST_JSON=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/$REPO/releases/latest")
    ASSET_URL=$(echo "$LATEST_JSON" | grep -o 'https://api.github.com/repos/[^"]*/assets/[0-9]*' | head -n 1)
    if [ -n "$ASSET_URL" ]; then
        curl -sL -H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/octet-stream" "$ASSET_URL" -o "$ZIP_PATH"
        if [ -s "$ZIP_PATH" ]; then
            DOWNLOAD_SUCCESS=true
        fi
    fi
fi

# Method C: Direct Public Download
if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo -e "   ${BLUE}→ Downloading from public releases...${NC}"
    PUBLIC_URL="https://github.com/$REPO/releases/latest/download/$ZIP_NAME"
    if curl -fsSL "$PUBLIC_URL" -o "$ZIP_PATH" 2>/dev/null; then
        DOWNLOAD_SUCCESS=true
    fi
fi

if [ "$DOWNLOAD_SUCCESS" = false ] || [ ! -f "$ZIP_PATH" ]; then
    echo ""
    echo -e "${RED}❌ Download failed!${NC}"
    echo "If the repository is private, ensure you are logged in with the GitHub CLI:"
    echo "  ${BOLD}gh auth login${NC}"
    echo "Or supply a personal access token:"
    echo "  ${BOLD}GITHUB_TOKEN=ghp_... curl -fsSL ... | bash${NC}"
    exit 1
fi

# 4. Extract and Install
echo -e "📦 [2/4] Installing $APP_NAME into $INSTALL_DIR..."
rm -rf "$APP_PATH"
unzip -q "$ZIP_PATH" -d "$INSTALL_DIR"

# 5. Remove Gatekeeper Quarantine Flag
echo -e "🔏 [3/4] Removing Gatekeeper quarantine flags..."
xattr -cr "$APP_PATH" 2>/dev/null || true

# 6. Install CLI Launcher (`anydiff` command)
echo -e "⚙️  [4/4] Setting up 'anydiff' CLI command in terminal..."

CLI_SCRIPT='#!/bin/sh
APP_EXECUTABLE="/Applications/AnyDiff.app/Contents/MacOS/AnyDiff"
if [ ! -f "$APP_EXECUTABLE" ]; then
    APP_EXECUTABLE="$HOME/Applications/AnyDiff.app/Contents/MacOS/AnyDiff"
fi

if [ "$#" -eq 0 ]; then
    "$APP_EXECUTABLE" "$(pwd)" >/dev/null 2>&1 &
else
    # Check if arg is a directory or file
    if [ -e "$1" ]; then
        ABS_PATH="$(cd "$(dirname "$1")" 2>/dev/null && pwd)/$(basename "$1")"
        "$APP_EXECUTABLE" "$ABS_PATH" >/dev/null 2>&1 &
    else
        "$APP_EXECUTABLE" "$1" >/dev/null 2>&1 &
    fi
fi
'

CLI_INSTALLED=false
for BIN_DIR in "/usr/local/bin" "$HOME/.local/bin" "$HOME/bin"; do
    if [ -d "$BIN_DIR" ] && [ -w "$BIN_DIR" ]; then
        echo "$CLI_SCRIPT" > "$BIN_DIR/anydiff"
        chmod +x "$BIN_DIR/anydiff"
        CLI_INSTALLED=true
        CLI_LOCATION="$BIN_DIR/anydiff"
        break
    fi
done

if [ "$CLI_INSTALLED" = false ]; then
    mkdir -p "$HOME/.local/bin"
    echo "$CLI_SCRIPT" > "$HOME/.local/bin/anydiff"
    chmod +x "$HOME/.local/bin/anydiff"
    CLI_LOCATION="$HOME/.local/bin/anydiff"
fi

echo ""
echo -e "${GREEN}${BOLD}✨ AnyDiff successfully installed!${NC}"
echo -e "📍 App Location: ${BOLD}$APP_PATH${NC}"
echo -e "💻 CLI Command:  ${BOLD}$CLI_LOCATION${NC}"
echo ""
echo -e "Usage from terminal:"
echo -e "  ${CYAN}anydiff .${NC}                      # Open diff in current repository"
echo -e "  ${CYAN}anydiff ~/dev/my-project${NC}       # Open diff in specific folder"
echo -e "  ${CYAN}anydiff <PR-URL-or-diff-file>${NC}  # Open GitHub PR or patch"
echo ""

# Launch on finish
open "$APP_PATH" 2>/dev/null || true
