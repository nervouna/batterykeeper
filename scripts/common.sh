# Shared helpers for the BatteryKeeper scripts. Sourced by them, not executed.
#
# shellcheck shell=bash disable=SC2034

# Absolute path of the checkout (or git worktree) that contains this script, so
# the scripts behave the same from any working directory.
BATTERYKEEPER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD_DIR="$BATTERYKEEPER_ROOT/build"
APP_NAME="BatteryKeeper"
INSTALLED_APP="/Applications/$APP_NAME.app"

die() {
    echo "error: $*" >&2
    exit 1
}

log() {
    echo "==> $*" >&2
}

# Compiles scripts/icon-tool.swift into build/icon-tool and sets ICON_TOOL to it. The icon
# scripts call the tool for the artwork checks and the renders (see that file).
build_icon_tool() {
    ICON_TOOL="$BUILD_DIR/icon-tool"
    mkdir -p "$BUILD_DIR"
    swiftc -O "$BATTERYKEEPER_ROOT/scripts/icon-tool.swift" -o "$ICON_TOOL" \
        || die "cannot compile scripts/icon-tool.swift"
}

# Reads the signing settings. They are never part of the repository: the file
# named by BATTERYKEEPER_SIGNING_ENV, or ${XDG_CONFIG_HOME:-$HOME/.config}/batterykeeper/signing.env,
# is the only source. A missing file means ad-hoc signing.
#
# Sets SIGN_ENV_FILE, SIGN_IDENTITY and SIGN_TEAM (the last two are empty for ad-hoc).
load_signing_env() {
    SIGN_ENV_FILE="${BATTERYKEEPER_SIGNING_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/batterykeeper/signing.env}"

    # Do not let values inherited from the caller's environment override the file.
    unset BATTERYKEEPER_CODESIGN_IDENTITY BATTERYKEEPER_TEAM_ID

    if [[ -r "$SIGN_ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$SIGN_ENV_FILE"
    elif [[ -n "${BATTERYKEEPER_SIGNING_ENV:-}" ]]; then
        log "signing env file '$SIGN_ENV_FILE' is not readable"
    fi

    SIGN_IDENTITY="${BATTERYKEEPER_CODESIGN_IDENTITY:-}"
    SIGN_TEAM="${BATTERYKEEPER_TEAM_ID:-}"

    if [[ -n "$SIGN_IDENTITY" && -z "$SIGN_TEAM" ]]; then
        die "BATTERYKEEPER_CODESIGN_IDENTITY is set but BATTERYKEEPER_TEAM_ID is not (see $SIGN_ENV_FILE)"
    fi
}
