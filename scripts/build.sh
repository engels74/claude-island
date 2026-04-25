#!/bin/bash
# Build Claude Atoll with ad-hoc signing
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
EXPORT_PATH="$BUILD_DIR/export"

# Check if built app version matches latest git tag
check_version_sync() {
    local info_plist="$1"
    LATEST_TAG=$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || true)
    LATEST_TAG="${LATEST_TAG#v}"
    if [ -n "$LATEST_TAG" ]; then
        CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info_plist" 2>/dev/null || true)
        if [ -n "$CURRENT_VERSION" ] && [ "$LATEST_TAG" != "$CURRENT_VERSION" ]; then
            echo "⚠️  Warning: Local version ($CURRENT_VERSION) differs from latest tag ($LATEST_TAG)"
            echo "   Update MARKETING_VERSION in ClaudeAtoll.xcodeproj"
            echo ""
        fi
    fi
}

echo "=== Building Claude Atoll (Ad-Hoc Signed) ==="
echo ""

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$EXPORT_PATH"

cd "$PROJECT_DIR"

# Build with ad-hoc signing
echo "Building..."
XCODEBUILD_OPTS=(
    build
    -scheme ClaudeAtoll
    -configuration Release
    -derivedDataPath "$BUILD_DIR/DerivedData"
    CODE_SIGN_IDENTITY=-
    DEVELOPMENT_TEAM=
    COPY_PHASE_STRIP=YES
    STRIP_INSTALLED_PRODUCT=YES
)

if command -v xcpretty >/dev/null 2>&1; then
    xcodebuild "${XCODEBUILD_OPTS[@]}" | xcpretty
else
    xcodebuild "${XCODEBUILD_OPTS[@]}"
fi

# Copy app to expected location
APP_OUTPUT="$BUILD_DIR/DerivedData/Build/Products/Release/Claude Atoll.app"
check_version_sync "$APP_OUTPUT/Contents/Info.plist"
cp -R "$APP_OUTPUT" "$EXPORT_PATH/"

echo ""
echo "=== Build Complete ==="
echo "App exported to: $EXPORT_PATH/Claude Atoll.app"
echo ""
echo "Next: Run ./scripts/create-release.sh --skip-notarization to create DMG"
