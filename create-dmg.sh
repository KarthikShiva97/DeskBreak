#!/bin/bash
set -euo pipefail

APP_NAME="StandupReminder"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="DeskBreak.dmg"
DMG_VOLUME_NAME="DeskBreak"
STAGING_DIR="dmg-staging"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}▸${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
fail()    { echo -e "${RED}✗${NC} $1"; exit 1; }

echo ""
echo -e "${BOLD}Creating DMG installer for DeskBreak${NC}"
echo ""

# ─── Build the app if not already built ──────────────────────────────────────
if [[ ! -d "${APP_BUNDLE}" ]]; then
    info "App bundle not found. Building first..."
    ./build.sh
    echo ""
fi

if [[ ! -d "${APP_BUNDLE}" ]]; then
    fail "App bundle not found at ${APP_BUNDLE}. Build failed."
fi

# ─── Create staging directory ────────────────────────────────────────────────
info "Preparing DMG contents..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

# Copy app bundle
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"

# Create Applications symlink for drag-and-drop install
ln -s /Applications "${STAGING_DIR}/Applications"

# ─── Create DMG ──────────────────────────────────────────────────────────────
info "Creating DMG..."
rm -f "${DMG_NAME}"

hdiutil create \
    -volname "${DMG_VOLUME_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_NAME}"

# ─── Clean up ────────────────────────────────────────────────────────────────
rm -rf "${STAGING_DIR}"

echo ""
success "DMG created: ${DMG_NAME}"
echo ""
echo -e "  Users can open the DMG and drag ${BOLD}${APP_NAME}${NC} to ${BOLD}Applications${NC}."
echo ""
