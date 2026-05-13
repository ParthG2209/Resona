#!/bin/bash
#
# build_dmg.sh — Build Resona.app and package it into a distributable DMG.
#
# Usage:
#   ./scripts/build_dmg.sh
#
# Prerequisites:
#   - Xcode (not just Command Line Tools)
#   - Run from the repo root: /Users/parthgupta/Coding/Resona
#
# Output:
#   - dist/Resona.dmg  (ready to upload / share)

set -euo pipefail

APP_NAME="Resona"
SCHEME="Resona"
BUILD_DIR="$(pwd)/build"
DIST_DIR="$(pwd)/dist"
DMG_STAGING="$(pwd)/build/dmg-staging"
DMG_OUTPUT="${DIST_DIR}/${APP_NAME}.dmg"
APP_PATH="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"

echo "──────────────────────────────────────────"
echo "  Resona DMG Builder"
echo "──────────────────────────────────────────"

# ── Step 1: Clean previous artifacts ──
echo ""
echo "▸ Cleaning previous build artifacts..."
rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

# ── Step 2: Archive the app ──
echo "▸ Building ${APP_NAME} (Release)..."
xcodebuild \
  -scheme "${SCHEME}" \
  -configuration Release \
  -derivedDataPath "${BUILD_DIR}" \
  -arch arm64 \
  -destination 'generic/platform=macOS' \
  build \
  2>&1 | tail -5

if [ ! -d "${APP_PATH}" ]; then
  echo "✘ Build failed — ${APP_PATH} not found."
  exit 1
fi

echo "✔ Build succeeded: ${APP_PATH}"

# ── Step 3: Create DMG staging area ──
echo "▸ Staging DMG contents..."
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"

# Copy the app bundle
cp -R "${APP_PATH}" "${DMG_STAGING}/"

# Create a symlink to /Applications for drag-and-drop install
ln -s /Applications "${DMG_STAGING}/Applications"

# ── Step 4: Create the DMG ──
echo "▸ Creating DMG..."
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_STAGING}" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "${DMG_OUTPUT}" \
  2>&1 | tail -3

if [ -f "${DMG_OUTPUT}" ]; then
  DMG_SIZE=$(du -sh "${DMG_OUTPUT}" | cut -f1)
  echo ""
  echo "══════════════════════════════════════════"
  echo "  ✔ DMG ready: dist/Resona.dmg (${DMG_SIZE})"
  echo "══════════════════════════════════════════"
  echo ""
  echo "  To distribute:"
  echo "    1. Upload dist/Resona.dmg to GitHub Releases or your site"
  echo "    2. Users open the DMG and drag Resona to Applications"
  echo "    3. First launch: Right-click → Open → Click Open"
  echo ""
else
  echo "✘ DMG creation failed."
  exit 1
fi

# ── Cleanup staging ──
rm -rf "${DMG_STAGING}"
