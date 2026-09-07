#!/bin/zsh
set -euo pipefail
SCRIPT_DIRECTORY="${0:A:h}"
DIST="${1:-${SCRIPT_DIRECTORY:h}/dist}"
DIST="${DIST:A}"
APP="${DIST}/TopDrop.app"
WORKER="${APP}/Contents/MacOS/TopDropNotesWorker"
/usr/bin/codesign --verify --deep --strict "${APP}"
for EXECUTABLE in "${APP}/Contents/MacOS/TopDrop" "${WORKER}"; do
    [[ "$(/usr/bin/lipo -archs "${EXECUTABLE}")" == arm64 ]] || exit 1
    /usr/bin/codesign --verify --strict "${EXECUTABLE}"
    /usr/bin/codesign -d --verbose=4 "${EXECUTABLE}" 2>&1 | /usr/bin/grep 'flags=.*runtime' >/dev/null
    /usr/bin/codesign -d --entitlements :- "${EXECUTABLE}" 2>/dev/null \
        | /usr/bin/plutil -extract 'com\.apple\.security\.automation\.apple-events' raw -o - - | /usr/bin/grep -x true >/dev/null
done
/usr/libexec/PlistBuddy -c 'Print NSScreenCaptureUsageDescription' "${APP}/Contents/Info.plist" >/dev/null
[[ -d "${APP}/Contents/Resources/TopDrop_TopDropApp.bundle" ]] || exit 1
for ZIP in TopDrop.app.zip TopDrop-source.zip; do /usr/bin/unzip -tq "${DIST}/${ZIP}"; done
"${SCRIPT_DIRECTORY}/TestAppInstallation.sh" "${APP}"
TEST_ROOT="$(/usr/bin/mktemp -d /private/tmp/topdrop-source-check.XXXXXX)"
cleanup() {
    [[ "${TEST_ROOT}" == /private/tmp/topdrop-source-check.* && ! -L "${TEST_ROOT}" ]] && /bin/rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT
mkdir -p "${TEST_ROOT}/source with spaces"
/usr/bin/ditto -x -k "${DIST}/TopDrop-source.zip" "${TEST_ROOT}/source with spaces"
SOURCE="${TEST_ROOT}/source with spaces/TopDrop"
[[ -f "${SOURCE}/Package.swift" && -f "${SOURCE}/LICENSE" && ! -e "${SOURCE}/.git" && ! -e "${SOURCE}/.build" ]] || exit 1
"${SOURCE}/Scripts/audit-source.sh" "${SOURCE}"
if [[ "${2:-}" == --rebuild-source ]]; then
    # Fresh scratch path, no original Git checkout or module cache.
    (cd "${SOURCE}" && Scripts/run-tests.sh && Scripts/build-app.sh && Scripts/verify-package.sh dist)
fi
print "Package signatures, arm64, runtime, entitlements and archives verified."
