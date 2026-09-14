#!/bin/sh
# refresh-blocklist.sh — re-fetch the upstream LG TV Blocklist SAFE tier
# into etc/blocklist-upstream-safe.txt. Preserves the attribution header.
#
# This script runs OFF-DEVICE on a workstation; it is not shipped to the TV.
#
# Optional env:
#   OYG_REFRESH_STRICT=1   also fetch the STRICT tier into
#                          etc/blocklist-upstream-strict.txt (best-effort,
#                          the upstream repo may not publish a strict tier
#                          yet — failure is non-fatal).
#
# It is safe to re-run; it overwrites the vendored file in place and
# prints source URL + SHA-256 of the body for audit.

set -u

OYG_HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$OYG_HERE/.." && pwd)
ETC="$ROOT/etc"

SAFE_URL="https://raw.githubusercontent.com/furkan-bayrak/lg-tv-blocklist/main/src/safe.txt"
SAFE_REPO="https://github.com/furkan-bayrak/lg-tv-blocklist"
LICENSE="CC BY 4.0"
RETRIEVED=$(date -u '+%Y-%m-%d')

SAFE_OUT="$ETC/blocklist-upstream-safe.txt"
STRICT_OUT="$ETC/blocklist-upstream-strict.txt"

have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '[refresh] %s\n' "$*"; }
warn() { printf '[refresh] WARN %s\n' "$*" >&2; }
err()  { printf '[refresh] ERR  %s\n' "$*" >&2; }

fetch_one() {
    url=$1
    out=$2
    label=$3

    log "fetching $label list from $url"
    if have curl; then
        body=$(curl -fsSL --max-time 30 "$url") || { warn "curl fetch failed for $url"; return 1; }
    elif have wget; then
        body=$(wget -qO- --timeout=30 "$url") || { warn "wget fetch failed for $url"; return 1; }
    else
        err "neither curl nor wget available"
        return 1
    fi

    if [ -z "$body" ]; then
        warn "empty body from $url"
        return 1
    fi

    tmp=$(mktemp 2>/dev/null) || { err "mktemp failed"; return 1; }
    {
        printf '# LG TV Blocklist — %s tier (vendored snapshot)\n' "$label"
        printf '#\n'
        printf '# SOURCE:   %s\n' "$url"
        printf '# REPO:     %s\n' "$SAFE_REPO"
        printf '# LICENSE:  %s — attribution to the upstream author is required.\n' "$LICENSE"
        printf '#           This file is included unmodified except for this header.\n'
        printf '# RETRIEVED: %s\n' "$RETRIEVED"
        printf '#\n'
        printf '# Refresh with: scripts/refresh-blocklist.sh\n'
        printf '# DO NOT EDIT BY HAND — re-run the refresher to update.\n'
        printf '#\n'
        printf '%s\n' "$body"
    } >"$tmp"

    mv "$tmp" "$out" || { err "cannot write $out"; return 1; }

    # Strip the header and compute checksum of the body for audit.
    body_only=$(awk 'BEGIN{p=0} /^# DO NOT EDIT BY HAND/{p=1; next} p==1 {print}' "$out")
    sum=$(printf '%s' "$body_only" | shasum -a 256 2>/dev/null \
        | awk '{print $1}')
    [ -z "$sum" ] && sum=$(printf '%s' "$body_only" | sha256sum 2>/dev/null \
        | awk '{print $1}')
    if [ -n "$sum" ]; then
        log "$label: $(wc -l <"$out" | tr -d ' ') lines; sha256(body)=$sum"
    else
        log "$label: $(wc -l <"$out" | tr -d ' ') lines; (sha256 tool unavailable)"
    fi
    return 0
}

main() {
    [ -d "$ETC" ] || { err "missing $ETC"; exit 1; }

    fetch_one "$SAFE_URL" "$SAFE_OUT" "SAFE" || {
        err "SAFE list refresh FAILED — leaving $SAFE_OUT untouched"
        exit 1
    }
    log "SAFE list written to $SAFE_OUT"

    if [ "${OYG_REFRESH_STRICT:-0}" = "1" ]; then
        strict_url="https://raw.githubusercontent.com/furkan-bayrak/lg-tv-blocklist/main/src/strict.txt"
        if fetch_one "$strict_url" "$STRICT_OUT" "STRICT"; then
            log "STRICT list written to $STRICT_OUT"
        else
            warn "STRICT list not available upstream (this is expected for now); skipping"
            rm -f "$STRICT_OUT" 2>/dev/null || true
        fi
    fi

    log "done. source=$SAFE_URL"
    log "do NOT copy this to the TV — install.sh ships etc/* to /var/lib/own-your-glass/etc/ on the device."
}

main "$@"