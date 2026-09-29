# Sourced by the device scripts. Resolves which phone to talk to, and says which source it used —
# a script that quietly picked a device would be a silent deviation.
#
# Order: an explicit argument wins; otherwise PHONE_DEVICE_ID from scripts/local.env, which is
# git-ignored because this repository is public (template: scripts/local.env.example). With
# neither, the script stops: there is no safe default device.

resolve_phone_device_id() {
    local explicit="$1"
    if [[ -n "$explicit" ]]; then
        echo "==> Phone: $explicit (from the command line)" >&2
        printf '%s\n' "$explicit"
        return 0
    fi
    if [[ -f scripts/local.env ]]; then
        # shellcheck source=/dev/null
        source scripts/local.env
    fi
    if [[ -z "${PHONE_DEVICE_ID:-}" ]]; then
        echo "error: no phone device id. Pass it as the first argument, or set PHONE_DEVICE_ID" >&2
        echo "       in scripts/local.env (copy scripts/local.env.example)." >&2
        echo "       Find it with: xcrun devicectl list devices" >&2
        exit 64
    fi
    echo "==> Phone: $PHONE_DEVICE_ID (from scripts/local.env)" >&2
    printf '%s\n' "$PHONE_DEVICE_ID"
}
