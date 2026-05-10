#!/bin/bash
set -euo pipefail

# Configuration
APP_NAME="MyEmail"
SCHEME="MyEmail"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_DIR="${BUILD_DIR}/dmg"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"
VOLUME_NAME="${APP_NAME}"

echo "=== Building ${APP_NAME} ==="
echo "Project: ${PROJECT_DIR}"

# Bump CURRENT_PROJECT_VERSION (+1) across all build configurations in project.pbxproj
PBXPROJ="${PROJECT_DIR}/${APP_NAME}.xcodeproj/project.pbxproj"
if [ ! -f "${PBXPROJ}" ]; then
    echo "ERROR: project.pbxproj not found at ${PBXPROJ}"
    exit 1
fi
CURRENT_BUILD=$(grep -m1 -E 'CURRENT_PROJECT_VERSION = [0-9]+;' "${PBXPROJ}" | grep -oE '[0-9]+')
if [ -z "${CURRENT_BUILD}" ]; then
    echo "ERROR: could not read CURRENT_PROJECT_VERSION from project.pbxproj"
    exit 1
fi
NEW_BUILD=$((CURRENT_BUILD + 1))
/usr/bin/sed -i '' -E "s/CURRENT_PROJECT_VERSION = ${CURRENT_BUILD};/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" "${PBXPROJ}"
echo "Build number: ${CURRENT_BUILD} → ${NEW_BUILD}"

# Prepare build dir (keep DerivedData for incremental builds)
mkdir -p "${BUILD_DIR}"
rm -rf "${BUILD_DIR}/${APP_NAME}.app"

# Build Release (incremental — only recompiles changed files)
xcodebuild \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}/DerivedData" \
    -destination 'platform=macOS' \
    build \
    2>&1 | tail -5

# Copy app from DerivedData to build dir
BUILT_APP=$(find "${BUILD_DIR}/DerivedData/Build/Products/Release" -name "${APP_NAME}.app" -maxdepth 1 2>/dev/null | head -1)
if [ -n "${BUILT_APP}" ]; then
    cp -R "${BUILT_APP}" "${APP_PATH}"
fi

if [ ! -d "${APP_PATH}" ]; then
    echo "ERROR: Build failed — ${APP_PATH} not found"
    exit 1
fi

echo ""
echo "=== Build succeeded ==="
echo "App: ${APP_PATH}"

# Get version info
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "${APP_PATH}/Contents/Info.plist")
DMG_FINAL="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"

echo "Version: ${VERSION} (${BUILD})"
echo ""
echo "=== Creating DMG ==="

# Prepare DMG contents
rm -rf "${DMG_DIR}"
mkdir -p "${DMG_DIR}"
cp -R "${APP_PATH}" "${DMG_DIR}/"
ln -s /Applications "${DMG_DIR}/Applications"

# Create DMG
rm -f "${DMG_FINAL}"
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${DMG_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_FINAL}" \
    2>&1 | grep -v "^$"

rm -rf "${DMG_DIR}"

echo ""
echo "=== DMG created ==="
echo "DMG: ${DMG_FINAL}"
echo "Size: $(du -h "${DMG_FINAL}" | cut -f1)"

# Open DMG
echo ""
echo "=== Opening DMG ==="
open "${DMG_FINAL}"

echo "Done!"
