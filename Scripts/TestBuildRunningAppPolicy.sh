#!/bin/zsh
set -euo pipefail
SCRIPT_DIRECTORY="${0:A:h}"
TEST_ROOT="$(/usr/bin/mktemp -d /private/tmp/topdrop-running-app-policy.XXXXXX)"
APP_PID=""
cleanup() {
    if [[ -n "${APP_PID}" ]]; then kill "${APP_PID}" 2>/dev/null || true; wait "${APP_PID}" 2>/dev/null || true; fi
    [[ "${TEST_ROOT}" == /private/tmp/topdrop-running-app-policy.* && ! -L "${TEST_ROOT}" ]] && /bin/rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT
mkdir -p "${TEST_ROOT}/Target/TopDrop.app/Contents/MacOS" "${TEST_ROOT}/cache"
/usr/bin/xcrun swiftc -module-cache-path "${TEST_ROOT}/cache" -parse-as-library \
    "${SCRIPT_DIRECTORY}/AppBundleSafety.swift" -o "${TEST_ROOT}/guard"
/bin/cp /bin/sleep "${TEST_ROOT}/Target/TopDrop.app/Contents/MacOS/TopDrop"
"${TEST_ROOT}/Target/TopDrop.app/Contents/MacOS/TopDrop" 30 &
APP_PID="$!"
/bin/sleep 0.1
if "${TEST_ROOT}/guard" "${TEST_ROOT}/Target/TopDrop.app" >/dev/null 2>&1; then
    print -u2 "Running target was not rejected"; exit 1
fi
"${TEST_ROOT}/guard" "${TEST_ROOT}/Other/TopDrop.app"
kill "${APP_PID}"; wait "${APP_PID}" 2>/dev/null || true; APP_PID=""
"${TEST_ROOT}/guard" "${TEST_ROOT}/Target/TopDrop.app"
if /usr/bin/grep -Eq 'killall|rm -rf' "${SCRIPT_DIRECTORY}/install-app.sh" "${SCRIPT_DIRECTORY}/uninstall-app.sh"; then
    print -u2 "Unsafe app replacement policy"; exit 1
fi
print "3/3 exact-target running-app policy tests passed"
