#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIRECTORY:h}"
BUILD_ROOT="${PROJECT_ROOT}/.build"
PUBLIC_DIST="${TOPDROP_OUTPUT_DIR:-${PROJECT_ROOT}/dist}"
source "${SCRIPT_DIRECTORY}/build-support.zsh"
source "${SCRIPT_DIRECTORY}/build-lock.zsh"
source "${SCRIPT_DIRECTORY}/artifact-publication.zsh"
MODULE_CACHE="${BUILD_ROOT}/module-cache"
CLANG_CACHE="${BUILD_ROOT}/clang-cache"

fail() {
    print -u2 -- "TopDrop build failed: $*"
    exit 1
}

cleanup() {
    if [[ -n "${STAGED_DIST:-}" ]]; then
        topdrop_cleanup_publication_stage "${OUTPUT_PARENT}" "${STAGED_DIST}"
    fi
    if [[ "${TEMPORARY_DIRECTORY:-}" == /private/tmp/topdrop-build.* && -d "${TEMPORARY_DIRECTORY:-}" ]]; then
        /bin/rm -rf -- "${TEMPORARY_DIRECTORY}"
    fi
    topdrop_release_build_lock
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
topdrop_acquire_build_lock "${PROJECT_ROOT}"
topdrop_select_toolchain
[[ "${PUBLIC_DIST}" == /* && "${PUBLIC_DIST}" != "/" ]] || fail "Output directory must be absolute"
[[ ! -L "${PUBLIC_DIST}" ]] || fail "Output directory must not be a symlink"
mkdir -p "${PUBLIC_DIST:h}" "${BUILD_ROOT}/tooling" "${MODULE_CACHE}" "${CLANG_CACHE}"
OUTPUT_PARENT="${PUBLIC_DIST:h:A}"
PUBLIC_DIST="${OUTPUT_PARENT}/${PUBLIC_DIST:t}"
/usr/bin/xcrun swiftc -module-cache-path "${CLANG_CACHE}" -parse-as-library \
    "${SCRIPT_DIRECTORY}/AppBundleSafety.swift" -o "${BUILD_ROOT}/tooling/AppBundleSafety"
/usr/bin/xcrun swiftc -module-cache-path "${CLANG_CACHE}" \
    "${SCRIPT_DIRECTORY}/AtomicArtifactPublisher.swift" -o "${BUILD_ROOT}/tooling/AtomicArtifactPublisher"
"${BUILD_ROOT}/tooling/AppBundleSafety" "${PUBLIC_DIST}/TopDrop.app"
# The publication helper refuses unrelated files in an existing destination.
TEMPORARY_DIRECTORY="$(/usr/bin/mktemp -d /private/tmp/topdrop-build.XXXXXX)"
STAGED_DIST="$(/usr/bin/mktemp -d "${OUTPUT_PARENT}/.topdrop-dist-stage.XXXXXXXX")"
APP_PATH="${STAGED_DIST}/TopDrop.app"
CONTENTS="${APP_PATH}/Contents"
SOURCE_ROOT="${TEMPORARY_DIRECTORY}/source/TopDrop"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources" \
    "${STAGED_DIST}" "${SOURCE_ROOT}" "${MODULE_CACHE}" "${CLANG_CACHE}"

print "Building TopDrop for arm64 with macOS SDK ${SDK_VERSION}"
cd "${PROJECT_ROOT}"
env \
    DEVELOPER_DIR="${DEVELOPER_DIRECTORY}" \
    SDKROOT="${SDK_PATH}" \
    SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}" \
    CLANG_MODULE_CACHE_PATH="${CLANG_CACHE}" \
    /usr/bin/xcrun --sdk macosx swift build \
        --disable-sandbox \
        --configuration release \
        --arch arm64 \
        --scratch-path "${BUILD_ROOT}" \
        --jobs 1 \
        --product TopDrop

BIN_PATH="$(env DEVELOPER_DIR="${DEVELOPER_DIRECTORY}" SDKROOT="${SDK_PATH}" \
    /usr/bin/xcrun --sdk macosx swift build \
        --disable-sandbox \
        --configuration release \
        --arch arm64 \
        --scratch-path "${BUILD_ROOT}" \
        --show-bin-path)"
[[ -x "${BIN_PATH}/TopDrop" ]] || fail "SwiftPM did not produce TopDrop"

env DEVELOPER_DIR="${DEVELOPER_DIRECTORY}" SDKROOT="${SDK_PATH}" \
    SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}" CLANG_MODULE_CACHE_PATH="${CLANG_CACHE}" \
    /usr/bin/xcrun --sdk macosx swift build --disable-sandbox --configuration release \
    --arch arm64 --scratch-path "${BUILD_ROOT}" --jobs 1 --product TopDropNotesWorker
/usr/bin/ditto "${BIN_PATH}/TopDropNotesWorker" "${CONTENTS}/MacOS/TopDropNotesWorker"
/usr/bin/codesign --force --sign - --options runtime --identifier com.personal.TopDrop.NotesWorker \
    --entitlements "${PROJECT_ROOT}/Packaging/TopDrop.entitlements" "${CONTENTS}/MacOS/TopDropNotesWorker"

/usr/bin/ditto "${BIN_PATH}/TopDrop" "${CONTENTS}/MacOS/TopDrop"
/usr/bin/ditto "${PROJECT_ROOT}/Packaging/Info.plist" "${CONTENTS}/Info.plist"
if [[ -d "${BIN_PATH}/TopDrop_TopDropApp.bundle" ]]; then
    /usr/bin/ditto \
        "${BIN_PATH}/TopDrop_TopDropApp.bundle" \
        "${CONTENTS}/Resources/TopDrop_TopDropApp.bundle"
fi
/usr/bin/ditto "${PROJECT_ROOT}/LICENSE" "${CONTENTS}/Resources/LICENSE"
/usr/bin/ditto \
    "${PROJECT_ROOT}/THIRD_PARTY_NOTICES.md" \
    "${CONTENTS}/Resources/THIRD_PARTY_NOTICES.md"

/usr/bin/codesign \
    --force \
    --sign - \
    --options runtime \
    --entitlements "${PROJECT_ROOT}/Packaging/TopDrop.entitlements" \
    "${APP_PATH}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
/usr/bin/file "${CONTENTS}/MacOS/TopDrop" | /usr/bin/grep -q 'arm64' \
    || fail "Packaged executable is not arm64"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "${APP_PATH}" "${STAGED_DIST}/TopDrop.app.zip"
/usr/bin/unzip -tq "${STAGED_DIST}/TopDrop.app.zip" >/dev/null

# Explicit source allowlist. Never archive the whole working directory or .git.
for ENTRY in Package.swift README.md CONTRIBUTING.md SECURITY.md LICENSE THIRD_PARTY_NOTICES.md .gitignore .gitattributes \
    .swift-format Sources Tests Scripts Packaging docs .github; do
    [[ ! -L "${PROJECT_ROOT}/${ENTRY}" ]] || fail "Source entry must not be a symlink"
    if [[ -e "${PROJECT_ROOT}/${ENTRY}" ]]; then
        /usr/bin/ditto "${PROJECT_ROOT}/${ENTRY}" "${SOURCE_ROOT}/${ENTRY}"
    fi
done
"${SCRIPT_DIRECTORY}/audit-source.sh" "${SOURCE_ROOT}"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "${SOURCE_ROOT}" "${STAGED_DIST}/TopDrop-source.zip"
/usr/bin/unzip -tq "${STAGED_DIST}/TopDrop-source.zip" >/dev/null

# Recheck immediately before the atomic commit; never kill an app to publish.
"${BUILD_ROOT}/tooling/AppBundleSafety" "${PUBLIC_DIST}/TopDrop.app"
"${BUILD_ROOT}/tooling/AtomicArtifactPublisher" "${OUTPUT_PARENT}" "${STAGED_DIST:t}" "${PUBLIC_DIST:t}"

print "Built ${PUBLIC_DIST}/TopDrop.app"
print "Built ${PUBLIC_DIST}/TopDrop.app.zip"
print "Built ${PUBLIC_DIST}/TopDrop-source.zip"
