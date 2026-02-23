#!/bin/bash
set -euo pipefail

APP_NAME="StandupReminder"
APP_BUNDLE="${APP_NAME}.app"
INSTALL_DIR="/Applications"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}▸${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}!${NC} $1"; }
fail()    { echo -e "${RED}✗${NC} $1"; exit 1; }

# ─── Welcome ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔═══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     StandupReminder Installer         ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════╝${NC}"
echo ""

# ─── Check macOS ─────────────────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
    fail "This app only runs on macOS. You appear to be on $(uname)."
fi

# Check macOS version (need 14+)
MACOS_VERSION=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo "$MACOS_VERSION" | cut -d. -f1)
if [[ "$MACOS_MAJOR" -lt 14 ]]; then
    fail "macOS 14 (Sonoma) or later is required. You have macOS $MACOS_VERSION."
fi
success "macOS $MACOS_VERSION — compatible"

# ─── Check for Swift / Xcode CLI Tools ───────────────────────────────────────
if ! command -v swift &>/dev/null; then
    warn "Swift compiler not found. You need Xcode Command Line Tools."
    echo ""
    info "Installing Command Line Tools (a dialog will appear)..."
    xcode-select --install 2>/dev/null || true
    echo ""
    echo -e "${YELLOW}After the install finishes, run this script again:${NC}"
    echo -e "  ${BOLD}./install.sh${NC}"
    echo ""
    exit 0
fi
SWIFT_VERSION=$(swift --version 2>&1 | head -1)
success "Swift found — $SWIFT_VERSION"

# ─── Build ───────────────────────────────────────────────────────────────────
echo ""
info "Building ${APP_NAME} (this may take a minute on first run)..."
echo ""

swift build -c release 2>&1 | while IFS= read -r line; do
    echo -e "  ${line}"
done

if [[ ! -f ".build/release/${APP_NAME}" ]]; then
    fail "Build failed — no binary produced. Check the errors above."
fi
success "Build succeeded"

# ─── Create App Bundle ───────────────────────────────────────────────────────
info "Creating app bundle..."

rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"

cp ".build/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/"

success "App bundle created"

# ─── Install to /Applications ────────────────────────────────────────────────
echo ""
info "Installing to ${INSTALL_DIR}..."

# Check if already installed and running
if pgrep -x "${APP_NAME}" &>/dev/null; then
    warn "${APP_NAME} is currently running. Quitting it first..."
    killall "${APP_NAME}" 2>/dev/null || true
    sleep 1
fi

# Remove old version if it exists
if [[ -d "${INSTALL_DIR}/${APP_BUNDLE}" ]]; then
    rm -rf "${INSTALL_DIR}/${APP_BUNDLE}"
    info "Replaced existing installation"
fi

cp -R "${APP_BUNDLE}" "${INSTALL_DIR}/"
success "Installed to ${INSTALL_DIR}/${APP_BUNDLE}"

# ─── Clean up build artifact in project dir ──────────────────────────────────
rm -rf "${APP_BUNDLE}"

# ─── Launch ──────────────────────────────────────────────────────────────────
echo ""
info "Launching ${APP_NAME}..."
open "${INSTALL_DIR}/${APP_BUNDLE}"
success "${APP_NAME} is running! Look for the 🧍 icon in your menu bar."

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔═══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          Install complete!             ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Tip:${NC} Open Preferences (Cmd+,) from the menu bar"
echo -e "  icon to enable ${BOLD}Launch at Login${NC} so it starts"
echo -e "  automatically every time you turn on your Mac."
echo ""
echo -e "  To uninstall later:"
echo -e "    rm -rf ${INSTALL_DIR}/${APP_BUNDLE}"
echo ""
