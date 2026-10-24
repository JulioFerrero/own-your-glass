#!/bin/sh
# watch-wake.sh — re-run the debloat app pass each time the TV wakes, since
# LG resumes from standby with the background-app preload switched back on.

OYG_ROOT=${OYG_ROOT:-/var/lib/own-your-glass}
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
            OYG_DEBLOAT_APPS_ONLY=1 "$OYG_ROOT/oyg" harden --only debloat \
                </dev/null >"$OYG_ROOT/wake.log" 2>&1
        fi
        prev=$state
    done <"$FIFO"
    wait "$lpid" 2>/dev/null
    lpid=""
    # The stream dropped; the TV may have slept and woken while it was down.
    prev=unknown
    sleep 5
done
