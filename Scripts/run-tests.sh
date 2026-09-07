#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIRECTORY:h}"
MODULE_CACHE="${PROJECT_ROOT}/.build/module-cache"
CLANG_CACHE="${PROJECT_ROOT}/.build/clang-cache"
DEVELOPER_DIRECTORY="$(/usr/bin/xcode-select -p)"

if [[ "${DEVELOPER_DIRECTORY}" != *.app/Contents/Developer ]]; then
    print -u2 "TopDrop tests require full Xcode 26 or newer."
    exit 1
fi

SDK_PATH="$(DEVELOPER_DIR="${DEVELOPER_DIRECTORY}" /usr/bin/xcrun --sdk macosx --show-sdk-path)"
mkdir -p "${MODULE_CACHE}" "${CLANG_CACHE}"
cd "${PROJECT_ROOT}"
for PRODUCT in TopDropNotesWorker TopDropNotesWorkerFixture; do
    env DEVELOPER_DIR="${DEVELOPER_DIRECTORY}" SDKROOT="${SDK_PATH}" \
        SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}" CLANG_MODULE_CACHE_PATH="${CLANG_CACHE}" \
        /usr/bin/xcrun --sdk macosx swift build --disable-sandbox --configuration debug \
        --arch arm64 --scratch-path "${PROJECT_ROOT}/.build" --jobs 1 --product "${PRODUCT}"
done
env \
    DEVELOPER_DIR="${DEVELOPER_DIRECTORY}" \
    SDKROOT="${SDK_PATH}" \
    SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}" \
    CLANG_MODULE_CACHE_PATH="${CLANG_CACHE}" \
    /usr/bin/xcrun --sdk macosx swift run \
        --disable-sandbox \
        --configuration debug \
        --arch arm64 \
        --scratch-path "${PROJECT_ROOT}/.build" \
        --jobs 1 \
        TopDropTests
