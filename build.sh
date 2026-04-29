#!/bin/bash
#
# build.sh — Build signed Tunnelblick release from command line
#
# Usage:
#   ./build.sh                    # Full build (third-party + app)
#   ./build.sh --skip-third-party # App only (third-party already built)
#   ./build.sh --clean            # Clean build products
#   ./build.sh --notarize         # Build + submit for notarization
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/tunnelblick"
THIRD_PARTY_DIR="$SCRIPT_DIR/third_party"
BUILD_DIR="$PROJECT_DIR/build"
SCHEME="Tunnelblick"
CONFIGURATION="Release"
SIGNING_IDENTITY="Developer ID Application: Evgeny Amosov (ZZ46P8LWV3)"
TEAM_ID="ZZ46P8LWV3"
BUNDLE_ID="net.tunnelblick.tunnelblick"

# Server settings
NEKRO_URL="https://nekro.efreet.ru"
NEKRO_API_TOKEN="2217940d36ad3c737f4cb62edd8bf590ee1b69a1fda25910dd5b4064cd08abef"

# Parse arguments
SKIP_THIRD_PARTY=false
CLEAN=false
NOTARIZE=false
UPLOAD=false

for arg in "$@"; do
    case "$arg" in
        --skip-third-party) SKIP_THIRD_PARTY=true ;;
        --clean)            CLEAN=true ;;
        --notarize)         NOTARIZE=true ;;
        --upload)           UPLOAD=true ;;
        --help|-h)
            echo "Usage: $0 [--skip-third-party] [--clean] [--notarize] [--upload]"
            echo ""
            echo "  --skip-third-party  Skip building third-party dependencies"
            echo "  --clean             Clean build products before building"
            echo "  --notarize          Submit to Apple for notarization after build"
            echo "  --upload            Upload DMG to nekro.efreet.ru"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            exit 1
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}==>${NC} $*"; }
warn()  { echo -e "${YELLOW}WARNING:${NC} $*"; }
error() { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    command -v xcodebuild >/dev/null 2>&1 || error "xcodebuild not found. Install Xcode."
    command -v codesign   >/dev/null 2>&1 || error "codesign not found."
    command -v hdiutil    >/dev/null 2>&1 || error "hdiutil not found."

    # Verify signing identity exists
    if ! security find-identity -v -p codesigning | grep -q "$TEAM_ID"; then
        error "Signing identity '$SIGNING_IDENTITY' not found in keychain.\n  Run: security find-identity -v -p codesigning"
    fi

    log "Prerequisites OK"
}

# Clean build
clean() {
    log "Cleaning build products..."
    rm -rf "$BUILD_DIR"
    log "Clean done"
}

# Build third-party dependencies
build_third_party() {
    log "Building third-party dependencies (universal: arm64 + x86_64)..."
    cd "$THIRD_PARTY_DIR"

    if [ ! -f Makefile ]; then
        error "third_party/Makefile not found"
    fi

    # Enable ARM build so Makefile uses both arm64 and x86_64 target architectures
    export TB_CAN_BUILD_ARM=1

    # Set configure host — each makefile overrides --host per target arch for cross-compilation
    export TB_CONFIGURE_HOST="$(uname -m)-apple-darwin"

    # Set SDK and deployment target for third-party builds
    export SDK_DIR="$(xcrun --show-sdk-path)"
    export MACOSX_DEPLOYMENT_TARGET="13.0"

    make
    local status=$?
    cd "$SCRIPT_DIR"

    if [ $status -ne 0 ]; then
        error "Third-party build failed"
    fi

    log "Third-party dependencies built successfully"
}

# Check that third-party products used by the app packaging exist.
# OpenVPN is built by tunnelblick/build-openvpn.sh from NEKROVPN_PATH.
check_third_party() {
    local products_dir="$THIRD_PARTY_DIR/products"
    local missing=()

    if [ ! -d "$products_dir/easy-rsa-tunnelblick" ]; then
        missing+=("$products_dir/easy-rsa-tunnelblick")
    fi

    if [ ! -d "$products_dir/tuntap" ]; then
        missing+=("$products_dir/tuntap")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        error "Third-party products not found:\n  ${missing[*]}\n  Run without --skip-third-party first."
    fi

    log "Third-party products found"
}

prepare_openvpn_wrapper() {
    log "Preparing openvpn wrapper build products..."
    BUILT_PRODUCTS_DIR="$BUILD_DIR/$CONFIGURATION" \
        bash "$PROJECT_DIR/build-openvpn.sh"
}

# Build Tunnelblick with xcodebuild
build_app() {
    log "Building Tunnelblick ($CONFIGURATION)..."
    log "Signing identity: $SIGNING_IDENTITY"

    cd "$PROJECT_DIR"

    # Build using xcodebuild with local build directory (Legacy-style)
    # SYMROOT/OBJROOT force output into tunnelblick/build/ as the existing scripts expect
    # ARCHS + ONLY_ACTIVE_ARCH=NO produce a universal (arm64 + x86_64) binary
    xcodebuild \
        -project Tunnelblick.xcodeproj \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        SYMROOT="$BUILD_DIR" \
        OBJROOT="$BUILD_DIR/Intermediates" \
        ARCHS="arm64 x86_64" \
        ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE="Manual" \
        OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
        2>&1 | tee "$BUILD_DIR/build.log"

    local status=${PIPESTATUS[0]}
    cd "$SCRIPT_DIR"

    if [ $status -ne 0 ]; then
        error "xcodebuild failed. See $BUILD_DIR/build.log"
    fi

    log "Build completed successfully"
}

# Verify the build
verify_build() {
    local app_path="$BUILD_DIR/$CONFIGURATION/Tunnelblick.app"
    local signed_app="$BUILD_DIR/$CONFIGURATION/Signed/Tunnelblick.app"
    local signed_dmg="$BUILD_DIR/$CONFIGURATION/Signed/Tunnelblick.dmg"

    log "Verifying build products..."

    # Check unsigned app
    if [ ! -d "$app_path" ]; then
        error "Tunnelblick.app not found at $app_path"
    fi

    # Check signed app
    if [ ! -d "$signed_app" ]; then
        error "Signed Tunnelblick.app not found at $signed_app"
    fi

    # Check signed dmg
    if [ ! -f "$signed_dmg" ]; then
        error "Signed Tunnelblick.dmg not found at $signed_dmg"
    fi

    # Verify code signature
    log "Verifying code signature..."
    codesign --verify --deep --strict --verbose=2 "$signed_app" 2>&1 || error "Code signature verification failed"

    # Verify with spctl (Gatekeeper)
    log "Verifying Gatekeeper acceptance..."
    spctl --assess --verbose --no-cache "$signed_app" 2>&1 || warn "spctl assessment failed (may need notarization)"

    # Print version info
    local version
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$signed_app/Contents/Info.plist" 2>/dev/null || true)
    local build_num
    build_num=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$signed_app/Contents/Info.plist" 2>/dev/null || true)

    log "Build products:"
    echo "  App (unsigned): $app_path"
    echo "  App (signed):   $signed_app"
    echo "  DMG (signed):   $signed_dmg"
    echo "  Version:        $version"
    echo "  Build:          $build_num"
    echo "  Size:           $(du -sh "$signed_dmg" | cut -f1)"

    log "Verification complete"
}

# Notarize the DMG
notarize() {
    local signed_dmg="$BUILD_DIR/$CONFIGURATION/Signed/Tunnelblick.dmg"

    if [ ! -f "$signed_dmg" ]; then
        error "Signed DMG not found at $signed_dmg"
    fi

    log "Submitting for notarization..."
    log "Bundle ID: $BUNDLE_ID"

    xcrun notarytool submit "$signed_dmg" \
        --keychain-profile "notarytool-profile" \
        --wait \
        2>&1

    local status=$?
    if [ $status -ne 0 ]; then
        warn "Notarization failed. You may need to set up credentials first:"
        echo "  xcrun notarytool store-credentials notarytool-profile --apple-id YOUR_APPLE_ID --team-id $TEAM_ID"
        exit 1
    fi

    log "Stapling notarization ticket..."
    xcrun stapler staple "$signed_dmg"

    log "Notarization complete"
}

# Upload DMG to server
upload_dmg() {
    local signed_dmg="$BUILD_DIR/$CONFIGURATION/Signed/Tunnelblick.dmg"

    if [ ! -f "$signed_dmg" ]; then
        error "Signed DMG not found at $signed_dmg"
    fi

    log "Uploading Tunnelblick.dmg to ${NEKRO_URL}"
    local http_code
    http_code=$(curl -s -o /tmp/upload-response.json -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${NEKRO_API_TOKEN}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${signed_dmg}" \
        "${NEKRO_URL}/api/admin/upload/Tunnelblick.dmg")

    if [ "${http_code}" != "200" ]; then
        error "Upload failed (HTTP ${http_code}): $(cat /tmp/upload-response.json 2>/dev/null)"
    fi

    log "Upload OK: $(cat /tmp/upload-response.json)"
}

# Main
main() {
    echo ""
    echo "============================================"
    echo "  Tunnelblick Release Build"
    echo "============================================"
    echo ""

    check_prerequisites

    if $CLEAN; then
        clean
    fi

    mkdir -p "$BUILD_DIR"

    if $SKIP_THIRD_PARTY; then
        check_third_party
    else
        build_third_party
    fi

    prepare_openvpn_wrapper

    build_app
    verify_build

    if $NOTARIZE; then
        notarize
    fi

    if $UPLOAD; then
        upload_dmg
    fi

    echo ""
    log "All done!"
}

main
