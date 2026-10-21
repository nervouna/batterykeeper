#!/usr/bin/env bash
# Regenerates the app icon set, App/Assets.xcassets/AppIcon.appiconset, from the
# artwork in design/icon.png: every macOS size (16, 32, 128, 256 and 512 pt at 1x
# and 2x), each downscaled from the source with sips, plus the set's Contents.json.
#
# Usage: scripts/make-icon.sh [--normalize]
#
# Before anything is generated the artwork must have a fully opaque interior (see
# scripts/icon-tool.swift): macOS draws an icon with a non-opaque interior with blotches,
# so the script refuses such artwork. --normalize first sets the alpha of every pixel
# with alpha 240 or more to 255 in design/icon.png itself, colour channels untouched.
#
# To replace the artwork, put a new 1024x1024 PNG at design/icon.png and run this
# script with --normalize, then scripts/check-icon-render.sh after a Release build.
# Running it on the committed artwork changes nothing. Xcode compiles the set into
# Assets.car (and AppIcon.icns) when the app is built.

set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
    echo "Usage: scripts/make-icon.sh [--normalize]" >&2
}

normalize=false
for arg in "$@"; do
    case "$arg" in
        --normalize) normalize=true ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

SOURCE="$BATTERYKEEPER_ROOT/design/icon.png"
ICON_SET="$BATTERYKEEPER_ROOT/App/Assets.xcassets/AppIcon.appiconset"
# Staged in build/ (git-ignored) and moved into place, so that a failure part way
# through never leaves the committed set half written.
STAGING="$BUILD_DIR/AppIcon.appiconset"

# Every icon of the set as "points scale"; the pixel size is points x scale.
SIZES=(
    "16 1" "16 2"
    "32 1" "32 2"
    "128 1" "128 2"
    "256 1" "256 2"
    "512 1" "512 2"
)

[[ -f "$SOURCE" ]] || die "the artwork ${SOURCE#"$BATTERYKEEPER_ROOT"/} does not exist"

width="$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/ { print $2 }')"
height="$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/ { print $2 }')"
[[ "$width" == 1024 && "$height" == 1024 ]] \
    || die "${SOURCE#"$BATTERYKEEPER_ROOT"/} must be 1024x1024 pixels, it is ${width}x${height}"

build_icon_tool

if $normalize; then
    # Written to build/ first and moved over the artwork, so that a failure never
    # leaves design/icon.png half written.
    normalized="$BUILD_DIR/icon-normalized.png"
    "$ICON_TOOL" normalize "$SOURCE" "$normalized" 240 >&2 \
        || die "cannot normalize ${SOURCE#"$BATTERYKEEPER_ROOT"/}"
    mv "$normalized" "$SOURCE"
    log "Normalized ${SOURCE#"$BATTERYKEEPER_ROOT"/} in place"
fi

if ! "$ICON_TOOL" check "$SOURCE"; then
    die "${SOURCE#"$BATTERYKEEPER_ROOT"/} is not fit to be the app icon, see above"
fi

rm -rf "$STAGING"
mkdir -p "$STAGING"

entries=()
for size in "${SIZES[@]}"; do
    read -r points scale <<<"$size"
    pixels=$((points * scale))
    suffix=""
    ((scale == 1)) || suffix="@${scale}x"
    filename="icon_${points}x${points}${suffix}.png"

    sips -z "$pixels" "$pixels" "$SOURCE" --out "$STAGING/$filename" >/dev/null
    entries+=("    { \"filename\" : \"$filename\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${points}x${points}\" }")
done

{
    echo '{'
    echo '  "images" : ['
    for i in "${!entries[@]}"; do
        if ((i + 1 < ${#entries[@]})); then
            echo "${entries[$i]},"
        else
            echo "${entries[$i]}"
        fi
    done
    echo '  ],'
    echo '  "info" : {'
    echo '    "author" : "xcode",'
    echo '    "version" : 1'
    echo '  }'
    echo '}'
} >"$STAGING/Contents.json"

plutil -convert json -o /dev/null "$STAGING/Contents.json" 2>/dev/null \
    || die "the generated Contents.json is not valid JSON"

rm -rf "$ICON_SET"
mkdir -p "$(dirname "$ICON_SET")"
mv "$STAGING" "$ICON_SET"
log "Wrote ${ICON_SET#"$BATTERYKEEPER_ROOT"/} from ${SOURCE#"$BATTERYKEEPER_ROOT"/}"
