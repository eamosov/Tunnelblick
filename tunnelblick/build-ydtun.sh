#!/bin/bash
#
# build-ydtun.sh
#
# Builds the ydtun binary from source using Rust/Cargo.
# Called as an Xcode Run Script build phase or manually.
#
# Output: ${BUILT_PRODUCTS_DIR}/ydtun  (or ./build/${CONFIGURATION}/ydtun when run outside Xcode)
#
# Requires: Rust toolchain (https://rustup.rs)
#
# Environment variables (set by Xcode or manually):
#   BUILT_PRODUCTS_DIR  - where to place the built binary
#   CONFIGURATION       - Debug or Release
#   ARCHS               - target architectures (e.g. "arm64" or "arm64 x86_64")

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
YDTUN_SRC_DIR="${SCRIPT_DIR}/../third_party/ydtun"

LIBVPX_VERSION="1.16.0"
LIBVPX_URL="https://github.com/webmproject/libvpx/archive/refs/tags/v${LIBVPX_VERSION}.tar.gz"
LIBVPX_CACHE_DIR="${YDTUN_SRC_DIR}/target/libvpx-cache"
DARWIN_KERNEL_VERSION="$(uname -r | cut -d. -f1)"

# Determine output directory
if [ -n "${BUILT_PRODUCTS_DIR:-}" ]; then
    OUTPUT_DIR="${BUILT_PRODUCTS_DIR}"
else
    CONFIGURATION="${CONFIGURATION:-Release}"
    OUTPUT_DIR="${SCRIPT_DIR}/build/${CONFIGURATION}"
fi

OUTPUT_BINARY="${OUTPUT_DIR}/ydtun"

# Check if Rust/Cargo is available
CARGO_BIN=""
for candidate in "$HOME/.cargo/bin/cargo" "$(which cargo 2>/dev/null)" "/opt/homebrew/bin/cargo" "/usr/local/bin/cargo"; do
    if [ -x "$candidate" ]; then
        CARGO_BIN="$candidate"
        break
    fi
done

if [ -z "$CARGO_BIN" ]; then
    echo "error: Rust toolchain not found. Install Rust from https://rustup.rs to build ydtun." >&2
    exit 1
fi

echo "Building ydtun with ${CARGO_BIN} ($(${CARGO_BIN} --version))"

# Check that source directory exists
if [ ! -d "${YDTUN_SRC_DIR}" ]; then
    echo "error: ydtun source not found at ${YDTUN_SRC_DIR}" >&2
    echo "  Run: git submodule add git@github.com:eamosov/ydtun.git third_party/ydtun" >&2
    exit 1
fi

if [ ! -f "${YDTUN_SRC_DIR}/Cargo.toml" ]; then
    echo "error: Cargo.toml not found in ${YDTUN_SRC_DIR}" >&2
    exit 1
fi

# Skip rebuild if binary exists and is newer than source
if [ -f "${OUTPUT_BINARY}" ]; then
    BINARY_TIME=$(stat -f %m "${OUTPUT_BINARY}" 2>/dev/null || echo 0)
    SOURCE_TIME=$(find "${YDTUN_SRC_DIR}/src" -name '*.rs' -newer "${OUTPUT_BINARY}" 2>/dev/null | head -1)
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
            echo "ydtun universal binary is up to date, skipping build"
            exit 0
        fi
    fi
fi

# ─── Build static libvpx for a given architecture ────────────────────────────
# Caches built library in target/libvpx-cache/{arch}/libvpx.a
build_static_libvpx() {
    local arch="$1"   # arm64 or x86_64
    local cache_dir="${LIBVPX_CACHE_DIR}/${arch}"
    local lib_file="${cache_dir}/lib/libvpx.a"

    # Return cached lib if it exists
    if [ -f "${lib_file}" ]; then
        echo "  Using cached static libvpx for ${arch}" >&2
        echo "${cache_dir}/lib"
        return
    fi

    echo "  Building static libvpx ${LIBVPX_VERSION} for ${arch}..." >&2

    local src_dir="${LIBVPX_CACHE_DIR}/src"

    # Download source if not cached
    if [ ! -d "${src_dir}" ]; then
        mkdir -p "${LIBVPX_CACHE_DIR}"
        local tarball="${LIBVPX_CACHE_DIR}/libvpx-${LIBVPX_VERSION}.tar.gz"
        if [ ! -f "${tarball}" ]; then
            echo "  Downloading libvpx ${LIBVPX_VERSION}..." >&2
            curl -sL "${LIBVPX_URL}" -o "${tarball}"
        fi
        tar xzf "${tarball}" -C "${LIBVPX_CACHE_DIR}"
        mv "${LIBVPX_CACHE_DIR}/libvpx-${LIBVPX_VERSION}" "${src_dir}"
    fi

    local build_dir="${LIBVPX_CACHE_DIR}/build-${arch}"
    rm -rf "${build_dir}"
    mkdir -p "${build_dir}" "${cache_dir}"

    local vpx_target="${arch}-darwin${DARWIN_KERNEL_VERSION}-gcc"

    # x86_64 needs yasm/nasm for SIMD assembly
    if [ "${arch}" = "x86_64" ]; then
        if ! command -v yasm >/dev/null 2>&1 && ! command -v nasm >/dev/null 2>&1; then
            if command -v brew >/dev/null 2>&1; then
                echo "  Installing nasm (required for x86_64 libvpx)..." >&2
                brew install nasm > /dev/null 2>&1
            else
                echo "error: nasm or yasm required for x86_64 libvpx build. Install with: brew install nasm" >&2
                exit 1
            fi
        fi
    fi

    cd "${build_dir}"
    "${src_dir}/configure" \
        --target="${vpx_target}" \
        --prefix="${cache_dir}" \
        --enable-static \
        --disable-shared \
        --disable-examples \
        --disable-unit-tests \
        --disable-tools \
        --disable-docs \
        --enable-pic \
        --enable-vp8 \
        --enable-vp9 \
        --enable-runtime-cpu-detect \
        --extra-cflags="-arch ${arch}" \
        --extra-cxxflags="-arch ${arch}" \
        > /dev/null 2>&1

    make -j"$(sysctl -n hw.ncpu)" > /dev/null 2>&1
    make install > /dev/null 2>&1
    cd "${YDTUN_SRC_DIR}"

    rm -rf "${build_dir}"

    if [ ! -f "${lib_file}" ]; then
        echo "error: Failed to build static libvpx for ${arch}" >&2
        exit 1
    fi

    echo "  Built static libvpx for ${arch}: ${lib_file}" >&2
    echo "${cache_dir}/lib"
}

mkdir -p "${OUTPUT_DIR}"

cd "${YDTUN_SRC_DIR}"

# Determine target architectures
TARGET_ARCHS="${ARCHS:-arm64 x86_64}"

# Determine cargo build profile
if [ "${CONFIGURATION:-Release}" = "Debug" ]; then
    CARGO_PROFILE=""
    CARGO_TARGET_DIR="debug"
else
    CARGO_PROFILE="--release"
    CARGO_TARGET_DIR="release"
fi

echo "Building ydtun for architectures: ${TARGET_ARCHS}"

# Ensure Rust targets are installed
for TARGET_ARCH in ${TARGET_ARCHS}; do
    case "${TARGET_ARCH}" in
        arm64)  RUST_TARGET="aarch64-apple-darwin" ;;
        x86_64) RUST_TARGET="x86_64-apple-darwin" ;;
        *)      echo "warning: unknown arch ${TARGET_ARCH}, skipping"; continue ;;
    esac
    rustup target add "${RUST_TARGET}" 2>/dev/null || true
done

# Build ydtun for each architecture
ARCH_BINARIES=""
for TARGET_ARCH in ${TARGET_ARCHS}; do
    case "${TARGET_ARCH}" in
        arm64)  RUST_TARGET="aarch64-apple-darwin" ;;
        x86_64) RUST_TARGET="x86_64-apple-darwin" ;;
        *)      continue ;;
    esac

    echo "Building ydtun for ${RUST_TARGET} (${TARGET_ARCH})..."

    # Build static libvpx for this architecture (cached after first build)
    VPX_LIB_PATH=$(build_static_libvpx "${TARGET_ARCH}")

    VPX_STATIC=1 \
    VPX_LIB_DIR="${VPX_LIB_PATH}" \
    PKG_CONFIG_PATH="${LIBVPX_CACHE_DIR}/${TARGET_ARCH}/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
    "${CARGO_BIN}" build ${CARGO_PROFILE} --target "${RUST_TARGET}" --bin ydtun

    ARCH_BINARY="${OUTPUT_DIR}/ydtun-${TARGET_ARCH}"
    cp "target/${RUST_TARGET}/${CARGO_TARGET_DIR}/ydtun" "${ARCH_BINARY}"

    # Verify no dynamic libvpx dependency
    if otool -L "${ARCH_BINARY}" 2>/dev/null | grep -q "libvpx"; then
        echo "error: ydtun binary for ${TARGET_ARCH} still dynamically links libvpx!" >&2
        otool -L "${ARCH_BINARY}" | grep "libvpx"
        exit 1
    fi

    echo "  Built ${ARCH_BINARY} ($(wc -c < "${ARCH_BINARY}" | tr -d ' ') bytes)"
    ARCH_BINARIES="${ARCH_BINARIES} ${ARCH_BINARY}"
done

# Create universal binary with lipo if multiple architectures, otherwise just copy
ARCH_COUNT=$(echo ${TARGET_ARCHS} | wc -w | tr -d ' ')
if [ "${ARCH_COUNT}" -gt 1 ]; then
    echo "Creating universal binary with lipo..."
    lipo -create ${ARCH_BINARIES} -output "${OUTPUT_BINARY}"
    echo "Universal ydtun built: ${OUTPUT_BINARY} ($(wc -c < "${OUTPUT_BINARY}" | tr -d ' ') bytes)"
    lipo -info "${OUTPUT_BINARY}"
    # Clean up single-arch binaries
    rm -f ${ARCH_BINARIES}
else
    mv ${ARCH_BINARIES} "${OUTPUT_BINARY}"
    echo "ydtun built: ${OUTPUT_BINARY} ($(wc -c < "${OUTPUT_BINARY}" | tr -d ' ') bytes)"
fi
