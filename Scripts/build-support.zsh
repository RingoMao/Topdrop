# Shared, side-effect-free build prerequisites.
topdrop_fail() { print -u2 -- "TopDrop: $*"; return 1; }

topdrop_select_toolchain() {
    DEVELOPER_DIRECTORY="${TOPDROP_DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
    [[ -d "${DEVELOPER_DIRECTORY}" ]] || { topdrop_fail "Selected developer directory does not exist"; return 1; }
    [[ "${DEVELOPER_DIRECTORY}" == *.app/Contents/Developer ]] || { topdrop_fail "Full Xcode 26 or newer is required"; return 1; }
    export DEVELOPER_DIR="${DEVELOPER_DIRECTORY}"
    SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
    SDK_VERSION="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
    [[ "${SDK_VERSION%%.*}" -ge 26 ]] || { topdrop_fail "macOS SDK 26 or newer is required"; return 1; }
    export SDKROOT="${SDK_PATH}"
}
