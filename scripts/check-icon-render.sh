#!/usr/bin/env bash
# Renders the icon that the system shows for a built app and checks it against the artwork
# (design/icon.png): the render must not have sizeable patches that differ from the artwork.
#
# Usage: scripts/check-icon-render.sh [<app>]   (default: build/BatteryKeeper.app, see scripts/build.sh)
#
# The app is copied to a new directory under build/ first: the system caches an app's
# icon by its path, so only a copy at a fresh path shows the icon the app has now. The
# copy and the renders (icon-256.png, icon-32.png) stay in that directory for inspection.
# Exits 1 when the render differs from the artwork at either size (see scripts/icon-tool.swift,
# compare, for the method and the thresholds).
#
# The 256 px comparison is the detector: it fails on the blotches that artwork with a
# non-opaque interior gets. The 32 px comparison is a smoke check only. At that size the base
# is about 26 px wide, so the check compares few pixels, and the same damage is not visible there.

set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

app="${1:-$BUILD_DIR/$APP_NAME.app}"
[[ -d "$app" ]] || die "$app does not exist, run scripts/build.sh release first"

SOURCE="$BATTERYKEEPER_ROOT/design/icon.png"
build_icon_tool

mkdir -p "$BUILD_DIR"
work="$(mktemp -d "$BUILD_DIR/icon-check.XXXXXX")"
ditto "$app" "$work/$APP_NAME.app"
log "Rendering the copy at ${work#"$BATTERYKEEPER_ROOT"/}"

"$ICON_TOOL" render "$work/$APP_NAME.app" "$work" 256 32

status=0
for size in 256 32; do
    log "Comparing the render at ${size} px with the artwork"
    "$ICON_TOOL" compare "$SOURCE" "$work/icon-$size.png" || status=1
done

if ((status == 0)); then
    log "The render matches the artwork at 256 px and 32 px"
else
    log "The render differs from the artwork, look at ${work#"$BATTERYKEEPER_ROOT"/}/icon-256.png"
fi
exit "$status"
