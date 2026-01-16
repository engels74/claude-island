#!/bin/bash
# Build Claude Island with ad-hoc signing
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
EXPORT_PATH="$BUILD_DIR/export"

echo "=== Building Claude Island (Ad-Hoc Signed) ==="
echo ""

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$EXPORT_PATH"

cd "$PROJECT_DIR"

# Build with ad-hoc signing
echo "Building..."
xcodebuild build \
    -scheme ClaudeIsland \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    COPY_PHASE_STRIP=YES \
    STRIP_INSTALLED_PRODUCT=YES \
    | xcpretty || xcodebuild build \
    -scheme ClaudeIsland \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    COPY_PHASE_STRIP=YES \
    STRIP_INSTALLED_PRODUCT=YES

# Copy app to expected location
APP_OUTPUT="$BUILD_DIR/DerivedData/Build/Products/Release/Claude Island.app"
cp -R "$APP_OUTPUT" "$EXPORT_PATH/"

echo ""
echo "=== Build Complete ==="
echo "App exported to: $EXPORT_PATH/Claude Island.app"
echo ""
echo "Next: Run ./scripts/create-release.sh --skip-notarization to create DMG"
