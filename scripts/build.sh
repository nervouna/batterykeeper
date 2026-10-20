#!/usr/bin/env bash
# Builds build/BatteryKeeper.app (with the helper inside) with xcodebuild.
#
# Usage: scripts/build.sh [debug|release]   (default: debug)
#
# Signing comes from the signing env file (see scripts/common.sh); without one the
# app is signed ad-hoc, and an ad-hoc app cannot run its privileged helper. All
# intermediate products live under build/.
#
# BATTERYKEEPER_NOTARIZABLE=1 (set by scripts/release.sh) makes a signed Release
# build acceptable to the notary service: no get-task-allow entitlement and a secure
# timestamp. It needs network access and does not affect Debug or ad-hoc builds.

set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
    echo "Usage: scripts/build.sh [debug|release]" >&2
}

if [[ $# -gt 1 ]]; then
    usage
    exit 2
fi

case "${1:-debug}" in
    debug) CONFIGURATION="Debug" ;;
    release) CONFIGURATION="Release" ;;
    *)
        usage
        exit 2
        ;;
esac

load_signing_env

if [[ -n "$SIGN_IDENTITY" ]]; then
    signing_overrides=("CODE_SIGN_STYLE=Manual" "CODE_SIGN_IDENTITY=$SIGN_IDENTITY" "DEVELOPMENT_TEAM=$SIGN_TEAM")
    log "Signing with the configured identity"
    if [[ "$CONFIGURATION" == "Release" && "${BATTERYKEEPER_NOTARIZABLE:-}" == "1" ]]; then
        signing_overrides+=("CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO" "OTHER_CODE_SIGN_FLAGS=--timestamp")
        log "Release signing for notarization: no get-task-allow, secure timestamp"
    fi
else
    signing_overrides=("CODE_SIGN_STYLE=Manual" "CODE_SIGN_IDENTITY=-" "DEVELOPMENT_TEAM=")
    log "No signing identity configured: building ad-hoc signed"
fi

derived_data="$BUILD_DIR/DerivedData"
log_file="$BUILD_DIR/xcodebuild-$CONFIGURATION.log"
mkdir -p "$BUILD_DIR"

log "Building $APP_NAME ($CONFIGURATION, full log: ${log_file#"$BATTERYKEEPER_ROOT"/})"
if ! xcodebuild \
    -project "$BATTERYKEEPER_ROOT/$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$derived_data" \
    "${signing_overrides[@]}" \
    build >"$log_file" 2>&1; then
    grep -E 'error:' "$log_file" | sort -u | head -n 40 >&2 || tail -n 40 "$log_file" >&2
    die "xcodebuild failed (full log: $log_file)"
fi

product="$derived_data/Build/Products/$CONFIGURATION/$APP_NAME.app"
[[ -d "$product" ]] || die "build succeeded but '$product' does not exist"
[[ -x "$product/Contents/MacOS/BatteryKeeperHelper" ]] || die "the helper is missing from $product"
[[ -f "$product/Contents/Library/LaunchDaemons/io.damao.batterykeeper.helper.plist" ]] \
    || die "the launchd plist is missing from $product"

# ditto keeps the bundle byte-identical, so the code signature stays valid.
rm -rf "${BUILD_DIR:?}/$APP_NAME.app"
ditto "$product" "$BUILD_DIR/$APP_NAME.app"

codesign --verify --strict --deep "$BUILD_DIR/$APP_NAME.app"
log "Built ${BUILD_DIR#"$BATTERYKEEPER_ROOT"/}/$APP_NAME.app ($CONFIGURATION)"
