#!/usr/bin/env bash
# Builds a notarized, stapled, distributable archive: build/release/BatteryKeeper-<version>.zip
#
# Usage: scripts/release.sh [--skip-notarize]
#
# Steps: Developer ID release build (hardened runtime, secure timestamp, no
# get-task-allow), signature checks, notarization (xcrun notarytool submit --wait),
# stapling, a zip of the stapled app, and a final check of the app extracted from
# that zip. The signing and notary settings come from the signing env file (see
# scripts/common.sh); they are never part of the repository.
#
# --skip-notarize stops after the signature checks and zips the signed but
# un-notarized app, to rehearse everything except the upload. That archive is not
# fit for distribution.
#
# The notary API key is passed to notarytool by path and is never read here. The
# issuer ID is read into a variable that is never printed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
    echo "Usage: scripts/release.sh [--skip-notarize]" >&2
}

skip_notarize=false
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) skip_notarize=true ;;
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

# Do not let notary settings inherited from the caller's environment stand in for
# the file (load_signing_env does the same for the signing identity).
unset BATTERYKEEPER_NOTARY_KEY BATTERYKEEPER_NOTARY_KEY_ID BATTERYKEEPER_NOTARY_ISSUER_FILE
load_signing_env

# --- Preflight: refuse before building anything. ---------------------------------

if [[ -z "$SIGN_IDENTITY" ]]; then
    die "no signing identity configured, refusing to build a release.
Set BATTERYKEEPER_CODESIGN_IDENTITY and BATTERYKEEPER_TEAM_ID in the signing env file
(currently $SIGN_ENV_FILE; BATTERYKEEPER_SIGNING_ENV overrides its path)."
fi

available_identities="$(security find-identity -v -p codesigning)"
if ! grep -qF -- "$SIGN_IDENTITY" <<<"$available_identities"; then
    die "the signing identity from $SIGN_ENV_FILE is not available in the keychain"
fi

NOTARY_ISSUER=""
if ! $skip_notarize; then
    missing=()
    [[ -n "${BATTERYKEEPER_NOTARY_KEY:-}" ]] || missing+=("BATTERYKEEPER_NOTARY_KEY")
    [[ -n "${BATTERYKEEPER_NOTARY_KEY_ID:-}" ]] || missing+=("BATTERYKEEPER_NOTARY_KEY_ID")
    [[ -n "${BATTERYKEEPER_NOTARY_ISSUER_FILE:-}" ]] || missing+=("BATTERYKEEPER_NOTARY_ISSUER_FILE")
    if ((${#missing[@]} > 0)); then
        die "notary settings are incomplete, missing: ${missing[*]}.
Set them in the signing env file (currently $SIGN_ENV_FILE; BATTERYKEEPER_SIGNING_ENV
overrides its path), or pass --skip-notarize to rehearse without notarizing."
    fi
    [[ -f "$BATTERYKEEPER_NOTARY_KEY" && -r "$BATTERYKEEPER_NOTARY_KEY" ]] \
        || die "BATTERYKEEPER_NOTARY_KEY does not name a readable file"
    [[ -f "$BATTERYKEEPER_NOTARY_ISSUER_FILE" && -r "$BATTERYKEEPER_NOTARY_ISSUER_FILE" ]] \
        || die "BATTERYKEEPER_NOTARY_ISSUER_FILE does not name a readable file"
    NOTARY_ISSUER="$(tr -d '[:space:]' <"$BATTERYKEEPER_NOTARY_ISSUER_FILE")"
    [[ -n "$NOTARY_ISSUER" ]] || die "the file named by BATTERYKEEPER_NOTARY_ISSUER_FILE is empty"
fi

# --- Helpers. --------------------------------------------------------------------

# Copies stdin to stderr with the issuer ID and the key path blanked out, so that
# notarytool diagnostics can be shown without leaking either.
redact() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//"$NOTARY_ISSUER"/<issuer>}"
        line="${line//"${BATTERYKEEPER_NOTARY_KEY:-}"/<key>}"
        printf '%s\n' "$line" >&2
    done
}

# notary <subcommand> [args...]: runs notarytool with the API key credentials.
notary() {
    local subcommand="$1"
    shift
    xcrun notarytool "$subcommand" "$@" \
        --key "$BATTERYKEEPER_NOTARY_KEY" \
        --key-id "$BATTERYKEEPER_NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER"
}

# check_code <path>: the code must be validly Developer ID signed with the hardened
# runtime and a secure timestamp, and must not carry get-task-allow (the notary
# service rejects all of these).
check_code() {
    local app="$1" details entitlements
    details="$(codesign -dvv "$app" 2>&1)"
    grep -q '^Authority=Developer ID Application' <<<"$details" \
        || die "$app is not signed with a Developer ID Application certificate"
    grep -Eq '^CodeDirectory .*flags=[^ ]*\([^)]*runtime' <<<"$details" \
        || die "$app was signed without the hardened runtime"
    grep -q '^Timestamp=' <<<"$details" \
        || die "$app was signed without a secure timestamp"

    entitlements="$(codesign -d --entitlements - "$app" 2>&1)"
    if grep -q 'get-task-allow' <<<"$entitlements"; then
        die "$app carries the get-task-allow entitlement"
    fi
}

# check_app <app>: the app and the privileged helper inside it pass check_code.
check_app() {
    local app="$1"
    codesign --verify --strict --deep "$app" 2>&1 || die "signature verification failed for $app"
    check_code "$app"
    check_code "$app/Contents/MacOS/BatteryKeeperHelper"
}

# notarize <app>: zips the app, submits it and waits for the verdict. On any
# verdict other than Accepted it prints the notary log and exits non-zero.
notarize() {
    local app="$1"
    local submit_zip="$RELEASE_DIR/$APP_NAME-notarize.zip"
    local result="$RELEASE_DIR/notary-submit.json"
    local errors="$RELEASE_DIR/notary-submit.err"
    local rc=0 status id

    ditto -c -k --keepParent "$app" "$submit_zip"

    log "Submitting to the notary service and waiting for the verdict (usually a few minutes)"
    notary submit "$submit_zip" --wait --timeout 30m --output-format json \
        >"$result" 2>"$errors" || rc=$?
    rm -f "$submit_zip"

    status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
    id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
    [[ -s "$errors" ]] && redact <"$errors"
    [[ -z "$id" && -s "$result" ]] && redact <"$result"
    rm -f "$result" "$errors"

    if [[ "$status" == "Accepted" ]]; then
        log "Notarization accepted (submission $id)"
        return 0
    fi

    if [[ -n "$id" ]]; then
        log "Notarization verdict: ${status:-unknown} (submission $id). Notary log:"
        notary log "$id" 2>&1 | redact || true
        die "notarization did not succeed (status: ${status:-unknown})"
    fi
    die "notarytool submit failed before a verdict was returned (exit code $rc)"
}

# staple <app>: attaches the ticket. The CDN can lag a little behind the verdict,
# so retry for a short while.
staple() {
    local app="$1" attempt
    for attempt in 1 2 3 4 5 6; do
        if xcrun stapler staple "$app" >&2; then
            return 0
        fi
        if ((attempt < 6)); then
            log "Stapling failed (attempt $attempt of 6), retrying in 10 seconds"
            sleep 10
        fi
    done
    die "could not staple the notarization ticket to $app"
}

# --- Build. ----------------------------------------------------------------------

RELEASE_DIR="$BUILD_DIR/release"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

BATTERYKEEPER_NOTARIZABLE=1 "$SCRIPT_DIR/build.sh" release

# Work on a copy: stapling modifies the bundle, and build/BatteryKeeper.app stays as built.
app="$RELEASE_DIR/$APP_NAME.app"
ditto "$BUILD_DIR/$APP_NAME.app" "$app"

log "Checking the signature"
check_app "$app"

# --- Notarize and staple. --------------------------------------------------------

if $skip_notarize; then
    log "Skipping notarization (--skip-notarize)"
else
    notarize "$app"
    log "Stapling the ticket"
    staple "$app"
    codesign --verify --strict --deep "$app" || die "signature verification failed after stapling"
fi

# --- Archive. --------------------------------------------------------------------

version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
[[ -n "$version" ]] || die "could not read the marketing version from $app"
archive="$RELEASE_DIR/$APP_NAME-$version.zip"

log "Creating ${archive#"$BATTERYKEEPER_ROOT"/}"
ditto -c -k --keepParent "$app" "$archive"

# --- Verify what would be distributed: the app as extracted from the archive. ----

verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/batterykeeper-release-verify.XXXXXX")"
trap 'rm -rf "$verify_dir"' EXIT
ditto -x -k "$archive" "$verify_dir"
extracted="$verify_dir/$APP_NAME.app"
[[ -d "$extracted" ]] || die "the archive does not contain $APP_NAME.app"

log "Verifying the app extracted from the archive"
check_app "$extracted"

if ! $skip_notarize; then
    xcrun stapler validate "$extracted" >&2 || die "stapler validate failed for the archived app"

    assessment="$(spctl --assess --type execute -vv "$extracted" 2>&1)" \
        || die "Gatekeeper rejected the archived app: $assessment"
    grep -v '^origin=' <<<"$assessment" >&2 || true # the origin line names the certificate
    grep -q '^source=Notarized Developer ID' <<<"$assessment" \
        || die "Gatekeeper accepted the archived app, but not as Notarized Developer ID"
fi

# --- Report. ---------------------------------------------------------------------

sha256="$(shasum -a 256 "$archive")"
sha256="${sha256%% *}"

if $skip_notarize; then
    log "WARNING: this archive is signed but NOT notarized or stapled, do not distribute it"
fi
echo "Archive: $archive"
echo "SHA-256: $sha256"
