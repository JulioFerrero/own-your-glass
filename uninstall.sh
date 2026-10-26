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

# kill_matching <text> — pkill -f, or a /proc scan where BusyBox was built
# without pkill (OpenEmbedded's 1.24.1 config, the webOS 4 era).
kill_matching() {
    if type pkill >/dev/null 2>&1; then
        pkill -f "$1" 2>/dev/null
        return 0
    fi
    for d in /proc/[0-9]*; do
        [ "${d#/proc/}" = "$$" ] && continue
        tr '\0' ' ' <"$d/cmdline" 2>/dev/null | grep -qF -- "$1" && kill -TERM "${d#/proc/}" 2>/dev/null
    done
    return 0
}

stop_watchers() {
    log "asking any running watchers to exit"
    kill_matching "$OYG_DST/watch-capture.sh"
    kill_matching "$OYG_DST/watch-logs.sh"
    kill_matching "$OYG_DST/scripts/watch-wake.sh"
    kill_matching "$OYG_DST/watchers"
}

# Every module, launcher, perms and remoteone included: restore only puts
# back what harden recorded, so it needs no opt-in flags. Returns 1 if any
# module could not be restored.
restore_hardening() {
    if [ ! -x "$OYG_DST/oyg" ]; then
        warn "oyg binary missing at $OYG_DST/oyg — skipping restore"
        return 0
    fi
    log "restoring prior state"
    "$OYG_DST/oyg" restore && return 0
    warn "one or more modules could not be restored (see above)"
    return 1
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
    if restore_hardening; then
        remove_init_hook
        remove_tool_tree
        log "uninstall complete"
        return 0
    fi
    # The backups are the only way back to what the TV had: keep them, and
    # the boot hook goes so nothing is re-applied.
    remove_init_hook
    err "uninstall stopped: $OYG_DST is kept, with the backups and state the failed restores need"
    err "fix what the warnings name, or reboot, then run 'sh $OYG_DST/uninstall.sh' again"
    exit 1
}

main "$@"
