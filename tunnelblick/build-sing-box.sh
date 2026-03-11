#!/bin/bash
#
# build-sing-box.sh
#
# Builds the sing-box binary from source using Go.
# Called as an Xcode Run Script build phase or manually.
#
# Output: ${BUILT_PRODUCTS_DIR}/sing-box  (or ./build/${CONFIGURATION}/sing-box when run outside Xcode)
#
# Requires: Go toolchain (https://go.dev)
#
# Environment variables (set by Xcode or manually):
#   BUILT_PRODUCTS_DIR  - where to place the built binary
#   CONFIGURATION       - Debug or Release
#   ARCHS               - target architectures (e.g. "arm64" or "arm64 x86_64")

set -e

SING_BOX_VERSION="1.11.7"
SING_BOX_REPO="github.com/sagernet/sing-box"
SING_BOX_TAGS="with_utls"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Determine output directory
if [ -n "${BUILT_PRODUCTS_DIR}" ]; then
    OUTPUT_DIR="${BUILT_PRODUCTS_DIR}"
else
    CONFIGURATION="${CONFIGURATION:-Release}"
    OUTPUT_DIR="${SCRIPT_DIR}/build/${CONFIGURATION}"
fi

OUTPUT_BINARY="${OUTPUT_DIR}/sing-box"

# Check if Go is available
GO_BIN=""
for candidate in "$(which go 2>/dev/null)" "/usr/local/go/bin/go" "/opt/homebrew/bin/go" "$HOME/go/bin/go"; do
    if [ -x "$candidate" ]; then
        GO_BIN="$candidate"
        break
    fi
done

if [ -z "$GO_BIN" ]; then
    echo "error: Go toolchain not found. Install Go from https://go.dev to build sing-box." >&2
    exit 1
fi

echo "Building sing-box ${SING_BOX_VERSION} with ${GO_BIN} ($(${GO_BIN} version))"

# Use a cache directory for the Go module
SING_BOX_BUILD_DIR="${SCRIPT_DIR}/build/sing-box-src"

# Download/update source if needed
if [ ! -d "${SING_BOX_BUILD_DIR}" ]; then
    echo "Cloning sing-box v${SING_BOX_VERSION}..."
    mkdir -p "$(dirname "${SING_BOX_BUILD_DIR}")"
    git clone --depth 1 --branch "v${SING_BOX_VERSION}" "https://${SING_BOX_REPO}" "${SING_BOX_BUILD_DIR}"
else
    # Check if the version matches
    CURRENT_TAG="$(cd "${SING_BOX_BUILD_DIR}" && git describe --tags --exact-match 2>/dev/null || echo "unknown")"
    if [ "${CURRENT_TAG}" != "v${SING_BOX_VERSION}" ]; then
        echo "Version mismatch (have ${CURRENT_TAG}, want v${SING_BOX_VERSION}), re-cloning..."
        rm -rf "${SING_BOX_BUILD_DIR}"
        git clone --depth 1 --branch "v${SING_BOX_VERSION}" "https://${SING_BOX_REPO}" "${SING_BOX_BUILD_DIR}"
    fi
fi

# Skip rebuild if binary exists and is newer than source
if [ -f "${OUTPUT_BINARY}" ]; then
    BINARY_TIME=$(stat -f %m "${OUTPUT_BINARY}" 2>/dev/null || echo 0)
    SOURCE_TIME=$(find "${SING_BOX_BUILD_DIR}" -name '*.go' -newer "${OUTPUT_BINARY}" 2>/dev/null | head -1)
    if [ -z "${SOURCE_TIME}" ] && [ "${BINARY_TIME}" -gt 0 ]; then
        echo "sing-box binary is up to date, skipping build"
        exit 0
    fi
fi

mkdir -p "${OUTPUT_DIR}"

cd "${SING_BOX_BUILD_DIR}"

# Determine target architecture
TARGET_ARCH="${ARCHS:-arm64}"
# If multiple archs specified, take the first one (Go builds single-arch)
TARGET_ARCH=$(echo "${TARGET_ARCH}" | awk '{print $1}')

# Map Xcode arch names to GOARCH
case "${TARGET_ARCH}" in
    arm64)  GOARCH="arm64" ;;
    x86_64) GOARCH="amd64" ;;
    *)      GOARCH="arm64" ;;
esac

echo "Building sing-box for ${GOARCH} with tags: ${SING_BOX_TAGS}"

# Build sing-box
CGO_ENABLED=0 GOOS=darwin GOARCH="${GOARCH}" \
    "${GO_BIN}" build \
    -tags "${SING_BOX_TAGS}" \
    -trimpath \
    -ldflags "-s -w -X '${SING_BOX_REPO}/constant.Version=${SING_BOX_VERSION}'" \
    -o "${OUTPUT_BINARY}" \
    ./cmd/sing-box

echo "sing-box built successfully: ${OUTPUT_BINARY} ($(wc -c < "${OUTPUT_BINARY}" | tr -d ' ') bytes)"
