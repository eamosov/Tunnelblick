#!/bin/bash
#
# build-openvpn.sh
#
# Builds the external OpenVPN wrapper from NekroVPN.
# Output: ${BUILT_PRODUCTS_DIR}/openvpn-wrapper
#         ${BUILT_PRODUCTS_DIR}/openvpn-down-root.so
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${NEKROVPN_PATH:-}" ]; then
    echo "error: NEKROVPN_PATH is required and must point to a NekroVPN checkout" >&2
    exit 1
fi

NEKROVPN_DIR="$(cd "${NEKROVPN_PATH}" 2>/dev/null && pwd)" || {
    echo "error: NEKROVPN_PATH does not exist or is not accessible: ${NEKROVPN_PATH}" >&2
    exit 1
}

NEKROVPN_BUILD_SCRIPT="${NEKROVPN_DIR}/build.sh"
NEKROVPN_WRAPPER="${NEKROVPN_DIR}/dist/darwin/openvpn"
NEKROVPN_PLUGIN_ARM64="${NEKROVPN_DIR}/prebuilt/darwin-arm64/openvpn-down-root.so"
NEKROVPN_PLUGIN_X86_64="${NEKROVPN_DIR}/prebuilt/darwin-amd64/openvpn-down-root.so"

if [ -n "${BUILT_PRODUCTS_DIR:-}" ]; then
    OUTPUT_DIR="${BUILT_PRODUCTS_DIR}"
else
    CONFIGURATION="${CONFIGURATION:-Release}"
    OUTPUT_DIR="${SCRIPT_DIR}/build/${CONFIGURATION}"
fi

OUTPUT_BINARY="${OUTPUT_DIR}/openvpn-wrapper"
OUTPUT_PLUGIN="${OUTPUT_DIR}/openvpn-down-root.so"

if [ ! -x "${NEKROVPN_BUILD_SCRIPT}" ]; then
    echo "error: NekroVPN build script is missing or not executable: ${NEKROVPN_BUILD_SCRIPT}" >&2
    exit 1
fi

for input in \
    "${NEKROVPN_PLUGIN_ARM64}" \
    "${NEKROVPN_PLUGIN_X86_64}"
do
    if [ ! -f "${input}" ]; then
        echo "error: required NekroVPN input not found: ${input}" >&2
        exit 1
    fi
done

mkdir -p "${OUTPUT_DIR}"

pushd "${NEKROVPN_DIR}" > /dev/null
bash ./build.sh darwin
popd > /dev/null

if [ ! -f "${NEKROVPN_WRAPPER}" ]; then
    echo "error: NekroVPN wrapper build did not produce ${NEKROVPN_WRAPPER}" >&2
    exit 1
fi

cp "${NEKROVPN_WRAPPER}" "${OUTPUT_BINARY}"
lipo -create \
    "${NEKROVPN_PLUGIN_ARM64}" \
    "${NEKROVPN_PLUGIN_X86_64}" \
    -output "${OUTPUT_PLUGIN}"

for output in \
    "${OUTPUT_BINARY}" \
    "${OUTPUT_PLUGIN}"
do
    if [ ! -f "${output}" ]; then
        echo "error: expected output was not produced: ${output}" >&2
        exit 1
    fi
    chmod 755 "${output}"
done

echo "Built openvpn wrapper: ${OUTPUT_BINARY}"
echo "Built openvpn down-root plugin: ${OUTPUT_PLUGIN}"
