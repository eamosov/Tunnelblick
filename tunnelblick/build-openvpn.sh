#!/bin/bash
#
# build-openvpn.sh
#
# Builds the external openvpn wrapper from third_party/openvpn.
# Output: ${BUILT_PRODUCTS_DIR}/openvpn-wrapper
#         ${BUILT_PRODUCTS_DIR}/openvpn-down-root.so
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER_DIR="${SCRIPT_DIR}/../third_party/openvpn"

if [ -n "${BUILT_PRODUCTS_DIR:-}" ]; then
    OUTPUT_DIR="${BUILT_PRODUCTS_DIR}"
else
    CONFIGURATION="${CONFIGURATION:-Release}"
    OUTPUT_DIR="${SCRIPT_DIR}/build/${CONFIGURATION}"
fi

OUTPUT_BINARY="${OUTPUT_DIR}/openvpn-wrapper"
OUTPUT_PLUGIN="${OUTPUT_DIR}/openvpn-down-root.so"

if [ ! -d "${WRAPPER_DIR}" ]; then
    echo "error: openvpn wrapper source not found at ${WRAPPER_DIR}" >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

pushd "${WRAPPER_DIR}" > /dev/null
bash ./build.sh darwin
cp ./openvpn "${OUTPUT_BINARY}"
if [ -f "./libs/darwin-arm64/openvpn-down-root.so" ] && [ -f "./libs/darwin-amd64/openvpn-down-root.so" ]; then
    lipo -create \
        "./libs/darwin-arm64/openvpn-down-root.so" \
        "./libs/darwin-amd64/openvpn-down-root.so" \
        -output "${OUTPUT_PLUGIN}"
else
    echo "error: darwin-arm64 and darwin-amd64 openvpn-down-root.so were not both produced by wrapper build" >&2
    exit 1
fi
popd > /dev/null

chmod 755 "${OUTPUT_BINARY}"
chmod 755 "${OUTPUT_PLUGIN}"
echo "Built openvpn wrapper: ${OUTPUT_BINARY}"
