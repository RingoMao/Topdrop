#!/bin/zsh
# Only private fixtures. Never targets /Applications or launches a GUI.
set -euo pipefail
SCRIPT_DIRECTORY="${0:A:h}"
SOURCE="${1:?Pass a verified TopDrop.app path}"
SOURCE="${SOURCE:A}"
TEST_ROOT="$(/usr/bin/mktemp -d /private/tmp/topdrop-install-test.XXXXXX)"
cleanup() {
    [[ "${TEST_ROOT}" == /private/tmp/topdrop-install-test.* && ! -L "${TEST_ROOT}" ]] && /bin/rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT
mkdir -p "${TEST_ROOT}/Applications"
TARGET="${TEST_ROOT}/Applications/TopDrop.app"
"${SCRIPT_DIRECTORY}/install-app.sh" "${SOURCE}" "${TARGET}"
/usr/bin/codesign --verify --deep --strict "${TARGET}"
"${SCRIPT_DIRECTORY}/install-app.sh" "${SOURCE}" "${TARGET}"
BACKUPS=("${TEST_ROOT}/Applications"/.TopDrop.backup-*.app(N))
(( ${#BACKUPS} == 1 )) || { print -u2 "Previous bundle backup missing"; exit 1; }
/usr/bin/codesign --verify --deep --strict "${BACKUPS[1]}"
# Invalid source must not remove or change the existing valid target.
mkdir -p "${TEST_ROOT}/Invalid.app"
if "${SCRIPT_DIRECTORY}/install-app.sh" "${TEST_ROOT}/Invalid.app" "${TARGET}" >/dev/null 2>&1; then exit 1; fi
/usr/bin/codesign --verify --deep --strict "${TARGET}"
# An unrelated pre-existing bundle and a symlink target must be preserved.
mkdir -p "${TEST_ROOT}/Unrelated/TopDrop.app" "${TEST_ROOT}/Linked"
if "${SCRIPT_DIRECTORY}/install-app.sh" "${SOURCE}" "${TEST_ROOT}/Unrelated/TopDrop.app" >/dev/null 2>&1; then exit 1; fi
/bin/ln -s "${TARGET}" "${TEST_ROOT}/Linked/TopDrop.app"
if "${SCRIPT_DIRECTORY}/install-app.sh" "${SOURCE}" "${TEST_ROOT}/Linked/TopDrop.app" >/dev/null 2>&1; then exit 1; fi
/usr/bin/codesign --verify --deep --strict "${TARGET}"
print "5/5 isolated installation tests passed (no user app replaced or launched)"
