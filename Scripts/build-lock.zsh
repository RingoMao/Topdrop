# Narrow, source-only ownership of TopDrop's build-wide advisory lock.
# Callers must source build-support.zsh first so topdrop_fail is available.

typeset -g TOPDROP_BUILD_LOCK_FD=""
typeset -g TOPDROP_BUILD_LOCK_VALIDATION_FD=""
typeset -g TOPDROP_BUILD_LOCK_PATH=""

topdrop_release_build_lock() {
    if [[ -n "${TOPDROP_BUILD_LOCK_FD}" ]]; then
        zsystem flock -u "${TOPDROP_BUILD_LOCK_FD}" 2>/dev/null || true
    fi
    if [[ -n "${TOPDROP_BUILD_LOCK_VALIDATION_FD}" ]]; then
        local validation_fd="${TOPDROP_BUILD_LOCK_VALIDATION_FD}"
        exec {validation_fd}>&-
    fi
    TOPDROP_BUILD_LOCK_FD=""
    TOPDROP_BUILD_LOCK_VALIDATION_FD=""
    TOPDROP_BUILD_LOCK_PATH=""
}

topdrop_acquire_build_lock() {
    local project_root="$1"
    local lock_path="${project_root}/.topdrop-build.lock"
    local validated_fd=""
    local locked_fd=""
    local expected_device=""
    local expected_inode=""
    local -A project_metadata
    local -A descriptor_metadata
    local -A path_metadata

    if [[ -n "${TOPDROP_BUILD_LOCK_FD}" ]] \
        || [[ -n "${TOPDROP_BUILD_LOCK_VALIDATION_FD}" ]]; then
        topdrop_fail "This shell already holds the TopDrop build lock"
        return 1
    fi
    if [[ "${project_root}" != /* ]] \
        || [[ "${project_root}" != "${project_root:A}" ]] \
        || [[ "${project_root}" == "/" ]]; then
        topdrop_fail "Refusing a non-canonical build-lock root: ${project_root}"
        return 1
    fi
    if ! zmodload zsh/system \
        || ! zmodload -F zsh/stat b:zstat; then
        topdrop_fail "The zsh system and stat modules are required for the build lock"
        return 1
    fi
    if ! zstat -L -H project_metadata "${project_root}" \
        || (( (project_metadata[mode] & 61440) != 16384 )) \
        || (( project_metadata[uid] != EUID )) \
        || (( (project_metadata[mode] & 18) != 0 )); then
        topdrop_fail "Build-lock root must be a trusted user-owned directory: ${project_root}"
        return 1
    fi

    # sysopen maps nofollow to O_NOFOLLOW and does not truncate unless the
    # explicit truncate option is present. Its close-on-exec descriptor stays
    # open for the lock lifetime to bind the fixed name to this exact inode.
    if ! sysopen -rw -m 600 -o create,nofollow,cloexec \
        -u validated_fd "${lock_path}"; then
        topdrop_fail "Could not safely open the fixed build lock: ${lock_path}"
        return 1
    fi

    if ! zstat -f "${validated_fd}" -H descriptor_metadata \
        || ! zstat -L -H path_metadata "${lock_path}" \
        || (( (descriptor_metadata[mode] & 61440) != 32768 )) \
        || (( descriptor_metadata[uid] != EUID )) \
        || (( descriptor_metadata[nlink] != 1 )) \
        || (( path_metadata[device] != descriptor_metadata[device] )) \
        || (( path_metadata[inode] != descriptor_metadata[inode] )); then
        exec {validated_fd}>&-
        topdrop_fail "Fixed build lock is not a trusted user-owned regular file"
        return 1
    fi

    # Migrate a lock created by an older build from 0644 to the fixed 0600
    # contract. stdin is duplicated from the validated close-on-exec descriptor
    # so chmod never resolves the mutable project pathname.
    if (( (descriptor_metadata[mode] & 511) != 384 )); then
        if ! /bin/chmod 600 /dev/fd/0 <&${validated_fd}; then
            exec {validated_fd}>&-
            topdrop_fail "Could not restrict the fixed build lock to mode 0600"
            return 1
        fi
    fi

    descriptor_metadata=()
    path_metadata=()
    if ! zstat -f "${validated_fd}" -H descriptor_metadata \
        || ! zstat -L -H path_metadata "${lock_path}" \
        || (( (descriptor_metadata[mode] & 61440) != 32768 )) \
        || (( (descriptor_metadata[mode] & 511) != 384 )) \
        || (( descriptor_metadata[uid] != EUID )) \
        || (( descriptor_metadata[nlink] != 1 )) \
        || (( path_metadata[device] != descriptor_metadata[device] )) \
        || (( path_metadata[inode] != descriptor_metadata[inode] )); then
        exec {validated_fd}>&-
        topdrop_fail "Fixed build lock changed during validation"
        return 1
    fi
    expected_device="${descriptor_metadata[device]}"
    expected_inode="${descriptor_metadata[inode]}"

    # zsystem retains a close-on-exec lock descriptor in this shell. Keep the
    # no-follow descriptor open across acquisition, prove that zsystem locked
    # that exact inode, and retain both descriptors for the full build lifetime.
    if ! zsystem flock -t 0 -f locked_fd "${lock_path}"; then
        exec {validated_fd}>&-
        topdrop_fail "Another TopDrop build already holds ${lock_path}"
        return 1
    fi

    descriptor_metadata=()
    path_metadata=()
    if ! zstat -f "${locked_fd}" -H descriptor_metadata \
        || ! zstat -L -H path_metadata "${lock_path}" \
        || (( descriptor_metadata[device] != expected_device )) \
        || (( descriptor_metadata[inode] != expected_inode )) \
        || (( descriptor_metadata[nlink] != 1 )) \
        || (( path_metadata[device] != descriptor_metadata[device] )) \
        || (( path_metadata[inode] != descriptor_metadata[inode] )); then
        zsystem flock -u "${locked_fd}" 2>/dev/null || true
        exec {validated_fd}>&-
        topdrop_fail "Fixed build lock changed while it was being acquired"
        return 1
    fi

    TOPDROP_BUILD_LOCK_FD="${locked_fd}"
    TOPDROP_BUILD_LOCK_VALIDATION_FD="${validated_fd}"
    TOPDROP_BUILD_LOCK_PATH="${lock_path}"
}
