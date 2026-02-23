#!/bin/bash
set -euo pipefail

APP_NAME="StandupReminder"
BUILD_DIR=".build"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

echo "==> Building ${APP_NAME}..."
swift build -c release

echo "==> Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"

# Copy binary
cp "${BUILD_DIR}/release/${APP_NAME}" "${MACOS_DIR}/"

# Copy Info.plist
cp Resources/Info.plist "${CONTENTS_DIR}/"

echo "==> Done! App bundle created at: ${APP_BUNDLE}"
echo ""
echo "To run:  open ${APP_BUNDLE}"
echo "To install: cp -R ${APP_BUNDLE} /Applications/"
