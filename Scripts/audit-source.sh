#!/bin/zsh
# Content-free allowlist checks; matches print filenames, never matching secrets.
set -euo pipefail
SOURCE_ROOT="${1:-${0:A:h:h}}"
[[ -d "${SOURCE_ROOT}/Sources" && -f "${SOURCE_ROOT}/LICENSE" ]] || exit 1
if /usr/bin/find "${SOURCE_ROOT}/Sources" "${SOURCE_ROOT}/Tests" "${SOURCE_ROOT}/Scripts" \
    "${SOURCE_ROOT}/Packaging" -type l -print | /usr/bin/grep . >/dev/null; then
    print -u2 "Source package contains symbolic links"; exit 1
fi
PATTERN='BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-[A-Za-z0-9]{32,}|/Users/[a-zA-Z][a-zA-Z0-9_-]+/'
if /usr/bin/grep -rEl "${PATTERN}" "${SOURCE_ROOT}/Sources" "${SOURCE_ROOT}/Tests" \
    "${SOURCE_ROOT}/Packaging"; then
    print -u2 "Review potentially private source content before publication"; exit 1
fi
for DIRECTORY in Sources Tests Scripts Packaging docs .github; do
    [[ -d "${SOURCE_ROOT}/${DIRECTORY}" ]] || continue
    if /usr/bin/find "${SOURCE_ROOT}/${DIRECTORY}" -type f \
        \( -name '*.enc' -o -name '*.tdclip' -o -name '.env*' -o -name '*.p12' -o -name '*.key' -o -name '*.log' -o -name '.DS_Store' \) \
        -print | /usr/bin/grep . >/dev/null; then
        print -u2 "Private/generated files found in source allowlist"; exit 1
    fi
done
print "Source allowlist checks passed (not a guarantee that no secrets exist)"
