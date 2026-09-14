#!/bin/sh
# watch-dns.sh — watchdog for the on-device DNS sinkhole resolver.
#
# Every loop (default: every 15 s):
#   1. if dns.applied=1, re-assert the resolv.conf override — ConnMan
#      regenerates /etc/resolv.conf, which would otherwise clobber our
#      nameservers. `dns.sh ensure` rewrites the managed file in place
#      and re-mounts only if the bind actually vanished (idempotent,
#      never stacks mounts).
#   2. probe the resolver; if it is dead, restart it (up to N tries).
#   3. if it will not come back, REVERT the override (umount) so the TV
#      falls back to ConnMan's own resolv.conf — never left without DNS
#      (the fallback nameserver in the override carries lookups in the
#      meantime).
#
# NEVER signals, reloads or restarts connmand. oyg_guard_connman_route
# refuses to start if any forbidden pattern sneaks back into these files
# (see the post-mortem in scripts/dns.sh).
#
# Started by install.sh's init.d/oyg boot hook (state-gated on
# dns.applied=1) or by scripts/dns.sh apply. Writes its own pid under
# $OYG_ROOT/watch-dns.pid so `dns.sh stop` can terminate it.
#
# Exit: never. Caller kills it with TERM.

set -u

OYG_HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$OYG_HERE/../lib/common.sh"

PROBE_INTERVAL=${OYG_WATCHDNS_INTERVAL:-15}
RESTART_TRIES=${OYG_WATCHDNS_TRIES:-3}
RESTART_GAP=${OYG_WATCHDNS_GAP:-2}
STATE_PID="$OYG_ROOT/dns.pid"
WATCHDOG_PID="$OYG_ROOT/watch-dns.pid"
DNS_BIND=127.0.0.2
DNS_PORT=53

printf '%s\n' "$$" >"$WATCHDOG_PID"

log_wd() { log "watch-dns: $*"; }
ok_wd()  { ok "watch-dns: $*"; }
warn_wd(){ warn "watch-dns: $*"; }
err_wd() { err "watch-dns: $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

resolver_alive() {
    [ -r "$STATE_PID" ] || return 1
    pid=$(cat "$STATE_PID" 2>/dev/null || true)
    [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null || return 1
    if have nslookup; then
        # Probe a BLOCKED name (instant local answer) — an allowed name
        # waits on the upstream and can false-negative under load.
        out=$(nslookup -port=53 -timeout=1 es.nextlgsdp.com "$DNS_BIND" 2>&1) || true
        printf '%s' "$out" | grep -Eq 'Address: ' && return 0
        return 1
    fi
    # Process alive but no nslookup -> assume still serving.
    return 0
}

restart_resolver() {
    pid=$(cat "$STATE_PID" 2>/dev/null || true)
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        sleep 0.5
    fi
    "$OYG_HERE/dns.sh" start >/dev/null 2>&1 || true
    sleep 1
    resolver_alive
}

main() {
    if ! oyg_guard_connman_route "$OYG_HERE/dns.sh" "$OYG_HERE/watch-dns.sh"; then
        err_wd "ConnMan signal/reload pattern detected — refusing to run"
        rm -f "$WATCHDOG_PID" 2>/dev/null || true
        exit 1
    fi
    log_wd "starting (interval=${PROBE_INTERVAL}s tries=${RESTART_TRIES})"
    trap 'rm -f "$WATCHDOG_PID" 2>/dev/null || true; exit 0' TERM INT

    while :; do
        sleep "$PROBE_INTERVAL" 2>/dev/null || sleep 1
        [ "$(state_get dns.applied 2>/dev/null)" = "1" ] || continue

        # Periodic re-apply: ConnMan regenerates resolv.conf and would
        # otherwise clobber our nameservers. Idempotent, never stacks.
        "$OYG_HERE/dns.sh" ensure >/dev/null 2>&1 \
            || warn_wd "re-assert of the resolv.conf override failed"

        resolver_alive && continue

        warn_wd "resolver not answering — attempting restart"
        ok=1
        i=1
        while [ "$i" -le "$RESTART_TRIES" ]; do
            if restart_resolver; then
                ok=0
                ok_wd "restart succeeded on try $i"
                break
            fi
            i=$((i + 1))
            sleep "$RESTART_GAP" 2>/dev/null || sleep 1
        done
        if [ "$ok" != "0" ]; then
            err_wd "resolver did not come back after $RESTART_TRIES tries — reverting the resolv.conf override"
            "$OYG_HERE/dns.sh" revert >/dev/null 2>&1 \
                || err_wd "revert failed; investigate manually"
        fi
    done
}

main "$@"