#!/bin/zsh
set -euo pipefail

TOPDROP_SCRIPT_DIRECTORY="${0:A:h}"
TOPDROP_PROJECT_ROOT="${TOPDROP_SCRIPT_DIRECTORY:h}"
source "${TOPDROP_SCRIPT_DIRECTORY}/build-support.zsh"
source "${TOPDROP_SCRIPT_DIRECTORY}/artifact-publication.zsh"
TOPDROP_PUBLISH_TEST_ROOT=""
TOPDROP_PUBLISH_TEST_COUNT=0

fail() {
    print -u2 -- "Atomic artifact publisher test failure: $*"
    return 1
}

cleanup() {
    if [[ -n "${TOPDROP_PUBLISH_TEST_ROOT}" ]] \
        && [[ "${TOPDROP_PUBLISH_TEST_ROOT:h}" == "${TOPDROP_PROJECT_ROOT}" ]] \
        && [[ "${TOPDROP_PUBLISH_TEST_ROOT:t}" == .topdrop-publish-tests.* ]] \
        && [[ -d "${TOPDROP_PUBLISH_TEST_ROOT}" ]] \
        && [[ ! -L "${TOPDROP_PUBLISH_TEST_ROOT}" ]]; then
        /bin/rm -rf -- "${TOPDROP_PUBLISH_TEST_ROOT}"
    fi
}

write_generation() {
    local root="$1"
    local stage_name="$2"
    local marker="$3"
    local stage="${root}/${stage_name}"

    mkdir -p "${stage}/TopDrop.app"
    print -rn -- "${marker}" > "${stage}/TopDrop.app/generation"
    print -rn -- "${marker}-app-zip" > "${stage}/TopDrop.app.zip"
    print -rn -- "${marker}-source-zip" > "${stage}/TopDrop-source.zip"
}

assert_marker() {
    local path="$1"
    local expected="$2"
    local actual

    if [[ ! -f "${path}" ]]; then
        fail "missing marker ${path}"
        return 1
    fi
    IFS= read -r actual < "${path}" || true
    if [[ "${actual}" != "${expected}" ]]; then
        fail "marker ${path} is '${actual}', expected '${expected}'"
        return 1
    fi
}

expect_rejection() {
    local publisher="$1"
    shift
    if "${publisher}" "$@" >/dev/null 2>&1; then
        fail "publisher unexpectedly accepted: $*"
        return 1
    fi
}

pass_test() {
    TOPDROP_PUBLISH_TEST_COUNT=$((TOPDROP_PUBLISH_TEST_COUNT + 1))
}

main() {
    local publisher_source="${TOPDROP_SCRIPT_DIRECTORY}/AtomicArtifactPublisher.swift"
    local publisher_binary
    local root
    local stage_name

    TOPDROP_PUBLISH_TEST_ROOT="$(
        /usr/bin/mktemp -d \
            "${TOPDROP_PROJECT_ROOT}/.topdrop-publish-tests.XXXXXX"
    )"
    trap cleanup EXIT
    publisher_binary="${TOPDROP_PUBLISH_TEST_ROOT}/AtomicArtifactPublisher"
    mkdir -p "${TOPDROP_PUBLISH_TEST_ROOT}/module-cache"
    env \
        CLANG_MODULE_CACHE_PATH="${TOPDROP_PUBLISH_TEST_ROOT}/module-cache" \
        SWIFT_MODULECACHE_PATH="${TOPDROP_PUBLISH_TEST_ROOT}/module-cache" \
        /usr/bin/xcrun --sdk macosx swiftc \
            -module-cache-path "${TOPDROP_PUBLISH_TEST_ROOT}/module-cache" \
            "${publisher_source}" \
            -o "${publisher_binary}"

    root="${TOPDROP_PUBLISH_TEST_ROOT}/initial"
    mkdir -p "${root}"
    stage_name=".topdrop-dist-stage.initial"
    write_generation "${root}" "${stage_name}" "initial"
    "${publisher_binary}" "${root}" "${stage_name}" dist >/dev/null
    [[ ! -e "${root}/${stage_name}" ]] \
        || fail "initial publication left the stage name behind"
    assert_marker "${root}/dist/TopDrop.app/generation" "initial"
    pass_test

    root="${TOPDROP_PUBLISH_TEST_ROOT}/swap"
    mkdir -p "${root}"
    stage_name=".topdrop-dist-stage.first"
    write_generation "${root}" "${stage_name}" "old"
    "${publisher_binary}" "${root}" "${stage_name}" dist >/dev/null
    stage_name=".topdrop-dist-stage.second"
    write_generation "${root}" "${stage_name}" "new"
    "${publisher_binary}" "${root}" "${stage_name}" dist >/dev/null
    assert_marker "${root}/dist/TopDrop.app/generation" "new"
    assert_marker "${root}/${stage_name}/TopDrop.app/generation" "old"
    topdrop_cleanup_publication_stage "${root}" "${root}/${stage_name}"
    [[ ! -e "${root}/${stage_name}" && ! -L "${root}/${stage_name}" ]] \
        || fail "post-swap cleanup retained the retired generation"
    assert_marker "${root}/dist/TopDrop.app/generation" "new"
    pass_test

    root="${TOPDROP_PUBLISH_TEST_ROOT}/extra"
    mkdir -p "${root}"
    stage_name=".topdrop-dist-stage.first"
    write_generation "${root}" "${stage_name}" "old"
    "${publisher_binary}" "${root}" "${stage_name}" dist >/dev/null
    stage_name=".topdrop-dist-stage.second"
    write_generation "${root}" "${stage_name}" "rejected"
    print -rn -- "unexpected" > "${root}/${stage_name}/extra"
    expect_rejection "${publisher_binary}" "${root}" "${stage_name}" dist
    assert_marker "${root}/dist/TopDrop.app/generation" "old"
    assert_marker "${root}/${stage_name}/TopDrop.app/generation" "rejected"
    pass_test

    root="${TOPDROP_PUBLISH_TEST_ROOT}/extra-public"
    mkdir -p "${root}"
    stage_name=".topdrop-dist-stage.first"
    write_generation "${root}" "${stage_name}" "old"
    "${publisher_binary}" "${root}" "${stage_name}" dist >/dev/null
    print -rn -- "unrelated" > "${root}/dist/unrelated-user-file"
    stage_name=".topdrop-dist-stage.second"
    write_generation "${root}" "${stage_name}" "rejected"
    expect_rejection "${publisher_binary}" "${root}" "${stage_name}" dist
    assert_marker "${root}/dist/TopDrop.app/generation" "old"
    assert_marker "${root}/dist/unrelated-user-file" "unrelated"
    assert_marker "${root}/${stage_name}/TopDrop.app/generation" "rejected"
    topdrop_cleanup_publication_stage "${root}" "${root}/${stage_name}"
    [[ ! -e "${root}/${stage_name}" && ! -L "${root}/${stage_name}" ]] \
        || fail "failed-publication cleanup retained the rejected generation"
    assert_marker "${root}/dist/TopDrop.app/generation" "old"
    assert_marker "${root}/dist/unrelated-user-file" "unrelated"
    pass_test

    root="${TOPDROP_PUBLISH_TEST_ROOT}/symbolic-artifact"
    mkdir -p "${root}/outside-app"
    stage_name=".topdrop-dist-stage.symbolic"
    mkdir -p "${root}/${stage_name}"
    /bin/ln -s "${root}/outside-app" "${root}/${stage_name}/TopDrop.app"
    print -rn -- "app-zip" > "${root}/${stage_name}/TopDrop.app.zip"
    print -rn -- "source-zip" > "${root}/${stage_name}/TopDrop-source.zip"
    expect_rejection "${publisher_binary}" "${root}" "${stage_name}" dist
    [[ ! -e "${root}/dist" ]] \
        || fail "symbolic artifact rejection created public dist"
    pass_test

    root="${TOPDROP_PUBLISH_TEST_ROOT}/symbolic-public"
    mkdir -p "${root}/outside-dist"
    print -rn -- "outside" > "${root}/outside-dist/marker"
    /bin/ln -s "${root}/outside-dist" "${root}/dist"
    stage_name=".topdrop-dist-stage.symbolicpublic"
    write_generation "${root}" "${stage_name}" "rejected"
    expect_rejection "${publisher_binary}" "${root}" "${stage_name}" dist
    assert_marker "${root}/outside-dist/marker" "outside"
    assert_marker "${root}/${stage_name}/TopDrop.app/generation" "rejected"
    pass_test

    root="${TOPDROP_PUBLISH_TEST_ROOT}/fixed-target"
    mkdir -p "${root}"
    stage_name=".topdrop-dist-stage.fixed"
    write_generation "${root}" "${stage_name}" "rejected"
    expect_rejection "${publisher_binary}" "${root}" "${stage_name}" ../other
    [[ ! -e "${root}/other" ]] \
        || fail "invalid public target was created"
    assert_marker "${root}/${stage_name}/TopDrop.app/generation" "rejected"
    pass_test

    print "${TOPDROP_PUBLISH_TEST_COUNT}/7 atomic artifact publisher tests passed"
}

main "$@"
