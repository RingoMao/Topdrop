# Narrow, source-only validation and cleanup for private publication stages.
# Callers must source build-support.zsh first so topdrop_fail is available.

topdrop_validate_publication_stage_path() {
    local project_root="$1"
    local stage_path="$2"
    local stage_name="${stage_path:t}"

    if [[ "${project_root}" != /* ]] \
        || [[ "${project_root}" != "${project_root:A}" ]] \
        || [[ "${project_root}" == "/" ]] \
        || [[ "${stage_path:h}" != "${project_root}" ]] \
        || [[ "${stage_name}" != .topdrop-dist-stage.* ]] \
        || [[ "${stage_name}" == ".topdrop-dist-stage." ]] \
        || [[ "${stage_path}" != "${project_root}/${stage_name}" ]]; then
        topdrop_fail "Refusing an invalid artifact publication stage: ${stage_path}"
        return 1
    fi
}

topdrop_cleanup_publication_stage() {
    local project_root="$1"
    local stage_path="$2"

    if [[ -z "${stage_path}" ]]; then
        return 0
    fi
    if ! topdrop_validate_publication_stage_path \
        "${project_root}" "${stage_path}"; then
        print -u2 \
            "TopDrop build warning: refusing to clean an invalid publication stage"
        return 0
    fi
    if [[ -L "${stage_path}" ]]; then
        print -u2 \
            "TopDrop build warning: refusing to clean a symbolic publication stage"
        return 0
    fi
    if [[ -e "${stage_path}" && ! -d "${stage_path}" ]]; then
        print -u2 \
            "TopDrop build warning: refusing to clean a non-directory publication stage"
        return 0
    fi
    if [[ -d "${stage_path}" ]] \
        && ! /bin/rm -rf -- "${stage_path}"; then
        print -u2 \
            "TopDrop build warning: could not clean ${stage_path}"
    fi
}
