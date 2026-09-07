#!/bin/zsh
set -euo pipefail
SCRIPT_DIRECTORY="${0:A:h}"
cd "${SCRIPT_DIRECTORY:h}"
source Scripts/build-support.zsh
topdrop_select_toolchain
Scripts/audit-source.sh
for SCRIPT in Scripts/*.sh Scripts/*.zsh; do /bin/zsh -n "${SCRIPT}"; done
/usr/bin/xcrun swift format lint --strict -r Sources Tests Scripts Package.swift
Scripts/run-tests.sh
/usr/bin/xcrun swift build --disable-sandbox --product TopDrop --jobs 1
Scripts/TestBuildLock.sh
Scripts/TestAtomicArtifactPublisher.sh
Scripts/TestBuildRunningAppPolicy.sh
print "All automated source checks passed; manual device/permission QA is separate."
