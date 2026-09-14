#!/bin/sh
# uninstall.sh — remove own-your-glass from the device.
# Calls `oyg restore` first (so prior state is restored), then removes files.

set -u

OYG_DST=${OYG_DST:-/var/lib/own-your-glass}
INIT_HOOK=${INIT_HOOK:-/var/lib/webosbrew/init.d/oyg}

log()  { printf '[uninstall] %s\n' "$*"; }
warn() { printf '[uninstall] WARN %s\n' "$*" >&2; }
err()  { printf '[uninstall] ERR  %s\n' "$*" >&2; }

require_root() {
    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        err "must be run as root on the device (or under sudo)"
        exit 1
    fi
}

stop_watchers() {
    log "asking any running watchers to exit"
    pkill -f "$OYG_DST/watch-capture.sh" 2>/dev/null || true
    pkill -f "$OYG_DST/watch-logs.sh"   2>/dev/null || true
    pkill -f "$OYG_DST/watchers"        2>/dev/null || true
}

restore_hardening() {
    if [ ! -x "$OYG_DST/oyg" ]; then
        warn "oyg binary missing at $OYG_DST/oyg — skipping restore"
        return 0
    fi
    log "restoring prior state"
    "$OYG_DST/oyg" restore --only services || warn "services restore failed"
    "$OYG_DST/oyg" restore --only capture  || warn "capture restore failed"
    "$OYG_DST/oyg" restore --only debloat  || warn "debloat restore failed"
    "$OYG_DST/oyg" restore --only mic      || warn "mic restore failed"
    "$OYG_DST/oyg" restore --only voice    || warn "voice restore failed"
    "$OYG_DST/oyg" restore --only logs     || warn "logs restore failed"
    "$OYG_DST/oyg" restore --only apps     || warn "apps restore failed"
    "$OYG_DST/oyg" restore --only policy   || warn "policy restore failed"
    "$OYG_DST/oyg" restore --only network  || warn "network restore failed"
    if [ "${OYG_AGGRESSIVE:-0}" = "1" ]; then
        "$OYG_DST/oyg" restore --only perms     || warn "perms restore failed"
        "$OYG_DST/oyg" restore --only remoteone || warn "remoteone restore failed"
    fi
}

remove_init_hook() {
    log "removing boot hook"
    if [ -e "$INIT_HOOK" ]; then
        rm -f "$INIT_HOOK" && log "removed $INIT_HOOK" || warn "could not remove $INIT_HOOK"
    else
        log "no boot hook present"
    fi
}

remove_tool_tree() {
    log "removing $OYG_DST"
    if [ -d "$OYG_DST" ]; then
        rm -rf "$OYG_DST" || warn "could not fully remove $OYG_DST"
    else
        log "no tool tree present"
    fi
    if [ -e /var/lib/own-your-glass/services.stopped ]; then
        rm -f /var/lib/own-your-glass/services.stopped \
            && log "removed /var/lib/own-your-glass/services.stopped" \
            || warn "could not remove /var/lib/own-your-glass/services.stopped"
    fi
    if [ -e /var/lib/own-your-glass/services.kill ]; then
        rm -f /var/lib/own-your-glass/services.kill \
            && log "removed /var/lib/own-your-glass/services.kill" \
            || warn "could not remove /var/lib/own-your-glass/services.kill"
    fi
}

main() {
    require_root
    stop_watchers
    restore_hardening
    remove_init_hook
    remove_tool_tree
    log "uninstall complete"
}

main "$@"
