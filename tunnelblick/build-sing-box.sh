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
for candidate in "/opt/homebrew/bin/go" "$(which go 2>/dev/null)" "/usr/local/go/bin/go" "$HOME/go/bin/go"; do
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

# Skip rebuild if binary exists, is newer than source, and has the right architectures
if [ -f "${OUTPUT_BINARY}" ]; then
    BINARY_TIME=$(stat -f %m "${OUTPUT_BINARY}" 2>/dev/null || echo 0)
    SOURCE_TIME=$(find "${SING_BOX_BUILD_DIR}" -name '*.go' -newer "${OUTPUT_BINARY}" 2>/dev/null | head -1)
    if [ -z "${SOURCE_TIME}" ] && [ "${BINARY_TIME}" -gt 0 ]; then
        # Check if the existing binary has all required architectures
        EXISTING_ARCHS=$(lipo -info "${OUTPUT_BINARY}" 2>/dev/null || echo "")
        NEED_REBUILD=false
        for a in ${ARCHS:-arm64 x86_64}; do
            if ! echo "${EXISTING_ARCHS}" | grep -q "${a}"; then
                NEED_REBUILD=true
                break
            fi
        done
        if [ "${NEED_REBUILD}" = false ]; then
            echo "sing-box universal binary is up to date, skipping build"
            exit 0
        fi
    fi
fi

mkdir -p "${OUTPUT_DIR}"

cd "${SING_BOX_BUILD_DIR}"

# Determine target architectures
TARGET_ARCHS="${ARCHS:-arm64 x86_64}"

echo "Building sing-box for architectures: ${TARGET_ARCHS} with tags: ${SING_BOX_TAGS}"

# Build sing-box for each architecture
ARCH_BINARIES=""
for TARGET_ARCH in ${TARGET_ARCHS}; do
    # Map Xcode arch names to GOARCH
    case "${TARGET_ARCH}" in
        arm64)  GOARCH="arm64" ;;
        x86_64) GOARCH="amd64" ;;
        *)      echo "warning: unknown arch ${TARGET_ARCH}, skipping"; continue ;;
    esac

    ARCH_BINARY="${OUTPUT_DIR}/sing-box-${TARGET_ARCH}"
    echo "Building sing-box for ${GOARCH} (${TARGET_ARCH})..."

    CGO_ENABLED=0 GOOS=darwin GOARCH="${GOARCH}" \
        "${GO_BIN}" build \
        -tags "${SING_BOX_TAGS}" \
        -trimpath \
        -ldflags "-s -w -X '${SING_BOX_REPO}/constant.Version=${SING_BOX_VERSION}'" \
        -o "${ARCH_BINARY}" \
        ./cmd/sing-box

    echo "  Built ${ARCH_BINARY} ($(wc -c < "${ARCH_BINARY}" | tr -d ' ') bytes)"
    ARCH_BINARIES="${ARCH_BINARIES} ${ARCH_BINARY}"
done

# Create universal binary with lipo if multiple architectures, otherwise just copy
ARCH_COUNT=$(echo ${TARGET_ARCHS} | wc -w | tr -d ' ')
if [ "${ARCH_COUNT}" -gt 1 ]; then
    echo "Creating universal binary with lipo..."
    lipo -create ${ARCH_BINARIES} -output "${OUTPUT_BINARY}"
    echo "Universal sing-box built: ${OUTPUT_BINARY} ($(wc -c < "${OUTPUT_BINARY}" | tr -d ' ') bytes)"
    lipo -info "${OUTPUT_BINARY}"
    # Clean up single-arch binaries
    rm -f ${ARCH_BINARIES}
else
    mv ${ARCH_BINARIES} "${OUTPUT_BINARY}"
    echo "sing-box built: ${OUTPUT_BINARY} ($(wc -c < "${OUTPUT_BINARY}" | tr -d ' ') bytes)"
fi
