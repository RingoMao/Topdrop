#!/bin/zsh
set -euo pipefail

TOPDROP_SCRIPT_DIRECTORY="${0:A:h}"
TOPDROP_PROJECT_ROOT="${TOPDROP_SCRIPT_DIRECTORY:h}"
source "${TOPDROP_SCRIPT_DIRECTORY}/build-support.zsh"
source "${TOPDROP_SCRIPT_DIRECTORY}/build-lock.zsh"

TOPDROP_LOCK_TEST_ROOT=""
TOPDROP_LOCK_TEST_COUNT=0

fail() {
    print -u2 -- "Build-lock test failure: $*"
    return 1
}

cleanup() {
    topdrop_release_build_lock
    if [[ -n "${TOPDROP_LOCK_TEST_ROOT}" ]] \
        && [[ "${TOPDROP_LOCK_TEST_ROOT:h}" == "${TOPDROP_PROJECT_ROOT}" ]] \
        && [[ "${TOPDROP_LOCK_TEST_ROOT:t}" == .topdrop-lock-tests.* ]] \
        && [[ -d "${TOPDROP_LOCK_TEST_ROOT}" ]] \
        && [[ ! -L "${TOPDROP_LOCK_TEST_ROOT}" ]]; then
        /bin/rm -rf -- "${TOPDROP_LOCK_TEST_ROOT}"
    fi
}

assert_file_content() {
    local path="$1"
    local expected="$2"
    local actual

    if [[ ! -f "${path}" ]]; then
        fail "missing file ${path}"
        return 1
    fi
    IFS= read -r actual < "${path}" || true
    if [[ "${actual}" != "${expected}" ]]; then
        fail "file ${path} is '${actual}', expected '${expected}'"
        return 1
    fi
}

assert_child_lock_result() {
    local project_root="$1"
    local expected_result="$2"
    local actual_result="success"

    if ! env \
        TOPDROP_LOCK_TEST_PROJECT_ROOT="${project_root}" \
        TOPDROP_LOCK_TEST_SCRIPT_DIRECTORY="${TOPDROP_SCRIPT_DIRECTORY}" \
        /bin/zsh -fc '
            set -euo pipefail
            source "${TOPDROP_LOCK_TEST_SCRIPT_DIRECTORY}/build-support.zsh"
            source "${TOPDROP_LOCK_TEST_SCRIPT_DIRECTORY}/build-lock.zsh"
            topdrop_acquire_build_lock "${TOPDROP_LOCK_TEST_PROJECT_ROOT}"
            topdrop_release_build_lock
        ' >/dev/null 2>&1; then
        actual_result="failure"
    fi
    if [[ "${actual_result}" != "${expected_result}" ]]; then
        fail \
            "child lock result is ${actual_result}, expected ${expected_result}"
        return 1
    fi
}

pass_test() {
    TOPDROP_LOCK_TEST_COUNT=$((TOPDROP_LOCK_TEST_COUNT + 1))
}

main() {
    local root
    local lock_path
    local target_path
    local lock_mode

    TOPDROP_LOCK_TEST_ROOT="$(
        /usr/bin/mktemp -d \
            "${TOPDROP_PROJECT_ROOT}/.topdrop-lock-tests.XXXXXX"
    )"
    trap cleanup EXIT

    root="${TOPDROP_LOCK_TEST_ROOT}/nontruncating"
    mkdir -p "${root}"
    lock_path="${root}/.topdrop-build.lock"
    print -rn -- "preserve-lock-content" > "${lock_path}"
    /bin/chmod 644 "${lock_path}"
    topdrop_acquire_build_lock "${root}"
    assert_file_content "${lock_path}" "preserve-lock-content"
    lock_mode="$(/usr/bin/stat -f '%Lp' "${lock_path}")"
    [[ "${lock_mode}" == "600" ]] \
        || fail "build lock mode is ${lock_mode}, expected 600"
    topdrop_release_build_lock
    pass_test

    root="${TOPDROP_LOCK_TEST_ROOT}/symbolic"
    mkdir -p "${root}"
    lock_path="${root}/.topdrop-build.lock"
    target_path="${TOPDROP_LOCK_TEST_ROOT}/symbolic-target"
    print -rn -- "preserve-symlink-target" > "${target_path}"
    /bin/chmod 640 "${target_path}"
    /bin/ln -s "${target_path}" "${lock_path}"
    if topdrop_acquire_build_lock "${root}" >/dev/null 2>&1; then
        fail "build lock unexpectedly followed a symbolic lock path"
        return 1
    fi
    assert_file_content "${target_path}" "preserve-symlink-target"
    lock_mode="$(/usr/bin/stat -f '%Lp' "${target_path}")"
    [[ "${lock_mode}" == "640" ]] \
        || fail "symbolic lock target mode changed to ${lock_mode}"
    [[ -L "${lock_path}" ]] || fail "symbolic lock path was replaced"
    pass_test

    root="${TOPDROP_LOCK_TEST_ROOT}/contention"
    mkdir -p "${root}"
    topdrop_acquire_build_lock "${root}"
    assert_child_lock_result "${root}" failure
    topdrop_release_build_lock
    assert_child_lock_result "${root}" success
    pass_test

    print "${TOPDROP_LOCK_TEST_COUNT}/3 build-lock tests passed"
}

main "$@"
