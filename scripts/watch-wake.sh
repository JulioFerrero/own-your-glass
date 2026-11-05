#!/bin/sh
# watch-wake.sh — on every wake from standby: re-assert the DNS sinkhole and
# re-run the debloat app pass. The resolver or its watchdog may not have
# survived standby (LG resumes with the background-app preload switched back
# on too); without the DNS step the TV wakes with no DNS until a cold reboot.

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

# on_wake — runs on each Active transition. Both steps are idempotent.
on_wake() {
    # DNS first: it is what puts the TV back on the internet after standby.
    # dns.sh start is idempotent — revives the resolver if standby killed it,
    # re-asserts the resolv.conf override, spawns the watchdog if it is gone.
    if [ "$(state_get network.dns_resolver 2>/dev/null)" = "1" ] \
        || [ "$(state_get dns.applied 2>/dev/null)" = "1" ]; then
        # Right after resume the link may not be back yet, and dns.sh start
        # would then fail its default-path check and revert the override —
        # wait (bounded) for a default route and a working lookup first.
        n=0
        while [ "$n" -lt 30 ]; do
            if ip route show default 2>/dev/null | grep -q '^default' \
                && { ! have nslookup \
                    || nslookup -timeout=2 www.youtube.com >/dev/null 2>&1; }; then
                break
            fi
            sleep 2 2>/dev/null || sleep 1
            n=$((n + 1))
        done
        sh "$OYG_HERE/dns.sh" start </dev/null >>"$OYG_ROOT/wake.log" 2>&1 \
            || echo "$(date '+%Y-%m-%dT%H:%M:%S') watch-wake: dns.sh start failed (see $OYG_ROOT/dns.log)" >>"$OYG_ROOT/wake.log"
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
