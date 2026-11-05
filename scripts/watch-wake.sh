#!/bin/sh
# watch-wake.sh — on wake from standby: re-assert the DNS sinkhole, then re-run the debloat app pass.

OYG_ROOT=${OYG_ROOT:-/var/lib/own-your-glass}
OYG_HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -r "$OYG_HERE/../lib/common.sh" ]; then
    . "$OYG_HERE/../lib/common.sh"
elif [ -r "$OYG_ROOT/lib/common.sh" ]; then
    . "$OYG_ROOT/lib/common.sh"
fi

URI=luna://com.webos.service.tvpower/power/getPowerState
FIFO="$OYG_ROOT/watchers/watch-wake.fifo"

# luna-send writes into a FIFO rather than a pipe so its pid is known and
# it dies with the watcher instead of holding the subscription open.
lpid=""
cleanup() {
    [ -n "$lpid" ] && kill "$lpid" 2>/dev/null
    rm -f "$FIFO"
}
trap 'cleanup; exit 0' TERM INT HUP
trap cleanup EXIT

# Runs on each Active transition; both steps are idempotent.
on_wake() {
    # DNS first — puts the TV back on the internet after standby. dns.sh start
    # revives the resolver, re-asserts the resolv.conf override, respawns the watchdog.
    : >"$OYG_ROOT/wake.log" 2>/dev/null || true
    if [ "$(state_get network.dns_resolver 2>/dev/null)" = "1" ] \
        || [ "$(state_get dns.applied 2>/dev/null)" = "1" ]; then
        up=$(state_get dns.upstream 2>/dev/null || true)
        # Wait (<=60 s) for the link; probe the upstream directly, never the
        # default path (resolv.conf may point at the dead sink).
        n=0
        while [ "$n" -lt 30 ]; do
            if ip route show default 2>/dev/null | grep -q '^default' \
                && { [ -z "$up" ] || ! have nslookup \
                    || nslookup -timeout=2 www.youtube.com "$up" >/dev/null 2>&1; }; then
                break
            fi
            sleep 2 2>/dev/null || sleep 1
            n=$((n + 1))
        done
        # Retry once after 45 s if the first start failed (link came up late).
        i=0
        while [ "$i" -lt 2 ]; do
            if sh "$OYG_HERE/dns.sh" start </dev/null >>"$OYG_ROOT/wake.log" 2>&1; then
                break
            fi
            i=$((i + 1))
            if [ "$i" -lt 2 ]; then
                warn "watch-wake: dns.sh start failed (try $i) — retrying in 45 s (see $OYG_ROOT/dns.log)" >>"$OYG_ROOT/wake.log" 2>&1
                sleep 45 2>/dev/null || sleep 45
            fi
        done
    fi
    OYG_DEBLOAT_APPS_ONLY=1 "$OYG_ROOT/oyg" harden --only debloat \
        </dev/null >>"$OYG_ROOT/wake.log" 2>&1
}

mkdir -p "$OYG_ROOT/watchers"
rm -f "$FIFO"
mkfifo "$FIFO" || exit 1

prev=""
while :; do
    luna-send -n 1000000 "$URI" '{"subscribe":true}' </dev/null >"$FIFO" 2>/dev/null &
    lpid=$!
    while IFS= read -r line; do
        # "processing" replies are steps inside a transition, not a settled state.
        case "$line" in *'"processing"'*) continue ;; esac
        state=$(printf '%s\n' "$line" | sed -n 's/.*"state": *"\([^"]*\)".*/\1/p')
        [ -n "$state" ] || continue
        if [ "$state" = Active ] && [ -n "$prev" ] && [ "$prev" != Active ]; then
            on_wake
        fi
        prev=$state
    done <"$FIFO"
    wait "$lpid" 2>/dev/null
    lpid=""
    # The stream dropped; the TV may have slept and woken while it was down.
    prev=unknown
    sleep 5
done
