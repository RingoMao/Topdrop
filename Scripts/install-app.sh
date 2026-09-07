#!/bin/zsh
set -euo pipefail
SCRIPT_DIRECTORY="${0:A:h}"
source "${SCRIPT_DIRECTORY}/build-support.zsh"
topdrop_select_toolchain
SOURCE_APP="${1:-${SCRIPT_DIRECTORY:h}/dist/TopDrop.app}"
DESTINATION_APP="${2:-/Applications/TopDrop.app}"
TOOLS="${SCRIPT_DIRECTORY:h}/.build/tooling"
mkdir -p "${TOOLS}/cache"
/usr/bin/xcrun swiftc -module-cache-path "${TOOLS}/cache" -D APP_BUNDLE_LIBRARY -parse-as-library \
    "${SCRIPT_DIRECTORY}/AppBundleSafety.swift" "${SCRIPT_DIRECTORY}/AppBundleManager.swift" -o "${TOOLS}/AppBundleManager"
"${TOOLS}/AppBundleManager" install "${SOURCE_APP}" "${DESTINATION_APP}"
# Installation does not launch the app or alter its permissions.
