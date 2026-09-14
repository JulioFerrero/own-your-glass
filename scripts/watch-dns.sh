#!/bin/sh
# watch-dns.sh — watchdog for the on-device DNS sinkhole resolver.
#
# Polls scripts/dns.sh's resolver liveness. If the resolver is dead:
#   1. Try to restart it (up to N times).
#   2. If still down, restore connman's original settings file from the
#      backup under $OYG_BACKUP, so the TV is never left without DNS.
#
# Designed to be started by install.sh's init.d/oyg boot hook (state-
# gated on dns.applied=1) or by scripts/dns.sh start. Writes its own
# pid under $OYG_ROOT/watch-dns.pid so dns.sh stop can terminate it.
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
CONNMAN_SERVICES_DIR=/var/lib/connman

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
        out=$(nslookup -port=53 -timeout=1 example.com "$DNS_BIND" 2>&1) || true
        printf '%s' "$out" | grep -Eq 'Address: ' && return 0
        return 1
    fi
    # Process alive but no nslookup -> assume still serving.
    return 0
}

# Roll back the connman override WITHOUT stopping the resolver, so we
# never leave the TV without DNS. Idempotent.
rollback_connman() {
    svc=$(state_get dns.service_dir 2>/dev/null || true)
    bak=$(state_get dns.original_settings 2>/dev/null || true)
    if [ -z "$svc" ] || [ -z "$bak" ] || [ ! -e "$bak" ]; then
        warn_wd "no original_settings backup at $bak — cannot auto-rollback"
        return 1
    fi
    if [ ! -f "$svc/settings" ]; then
        warn_wd "$svc/settings missing — cannot auto-rollback"
        return 1
    fi
    if cp -p "$bak" "$svc/settings" 2>/dev/null; then
        ok_wd "auto-restored $svc/settings from $bak (resolver is down)"
        if have pidof; then
            cm=$(pidof connmand 2>/dev/null | awk '{print $1; exit}') || true
            [ -n "${cm:-}" ] && kill -HUP "$cm" 2>/dev/null || true
        fi
        state_drop dns.applied
        state_drop dns.connmand_pid
        return 0
    fi
    err_wd "auto-rollback cp failed; TV may be without DNS!"
    return 1
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
    log_wd "starting (interval=${PROBE_INTERVAL}s tries=${RESTART_TRIES})"
    trap 'rm -f "$WATCHDOG_PID" 2>/dev/null || true; exit 0' TERM INT

    while :; do
        sleep "$PROBE_INTERVAL" 2>/dev/null || sleep 1
        if [ "$(state_get dns.applied 2>/dev/null)" != "1" ]; then
            continue
        fi
        if resolver_alive; then
            continue
        fi
        warn_wd "resolver dead — attempting restart"
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
            err_wd "resolver did not come back after $RESTART_TRIES tries — auto-rolling connman back"
            rollback_connman || err_wd "auto-rollback failed; investigate manually"
        fi
    done
}

main "$@"
