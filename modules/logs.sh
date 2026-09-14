OYG_MOD_LOGS=1

# logs.sh — privacy hygiene for RAM-disk logs.
#
# /tmp/var/log/messages and /tmp/app.voice.log on webOS TVs can contain
# plaintext voice transcripts BEFORE we get a chance to do anything.
# We cannot prevent the transcription; we can only limit its lifetime.
#
# This module:
#   - records the finding
#   - installs a periodic clearer (configurable via OYG_LOG_INTERVAL,
#     default 60s) into the watcher dir
#   - the boot hook will respawn it

LOG_INTERVAL=${OYG_LOG_INTERVAL:-60}
MSG_LOG=/tmp/var/log/messages
VOICE_LOG=/tmp/app.voice.log
WATCH_SCRIPT_DST="$OYG_ROOT/watch-logs.sh"

# Resolve a path to its absolute, canonical form for same-file comparison.
# BusyBox `readlink -f` is not portable; fall back to a manual normalisation
# (collapse repeated slashes, drop trailing slashes and a trailing `/.`)
# which is enough to detect the common src==dst case the install path
# produces.
_path_canon() {
    p=$1
    if have readlink; then
        canon=$(readlink -f "$p" 2>/dev/null) && [ -n "$canon" ] && { printf '%s\n' "$canon"; return 0; }
    fi
    printf '%s' "$p" | tr -s '/' '/' | sed -E 's:^\./::; s:/\.$::; s:/+$::'
}

mod_logs_install_watcher() {
    ensure_dirs
    src="$OYG_ROOT/watch-logs.sh"
    dst="$WATCH_SCRIPT_DST"
    [ -f "$src" ] || { err "logs watcher template missing"; return 1; }
    if [ "$(_path_canon "$src")" = "$(_path_canon "$dst")" ]; then
        if [ -x "$dst" ]; then
            ok "logs: watcher already installed at $dst"
            return 0
        fi
        run chmod 0755 "$dst" 2>/dev/null || true
        if [ -x "$dst" ]; then
            ok "logs: watcher already present at $dst (mode tightened)"
            return 0
        fi
        warn "logs: watcher src==dst but not executable; ignoring"
        return 0
    fi
    if ! run cp "$src" "$dst"; then
        err "cannot install watcher"
        return 1
    fi
    run chmod 0755 "$dst" 2>/dev/null || true
    return 0
}

mod_logs_harden() {
    require_root
    ensure_dirs

    for f in "$MSG_LOG" "$VOICE_LOG"; do
        if [ -e "$f" ]; then
            sz=$(stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f" 2>/dev/null || echo unknown)
            warn "logs: $f exists (size=$sz) — clearing now + periodically"
            : >"$f" 2>/dev/null || warn "logs: cannot truncate $f"
        else
            warn "logs: $f not present yet"
        fi
    done

    mod_logs_install_watcher || warn "logs: watcher install failed"
    state_put "logs.watcher" "$WATCH_SCRIPT_DST"
    state_put "logs.interval" "$LOG_INTERVAL"
    state_put "logs.applied" "1"
    warn "logs: this is DAMAGE LIMITATION — transcription happens before we can intervene"
}

mod_logs_restore() {
    state_drop "logs.watcher"
    state_drop "logs.interval"
    state_drop "logs.applied"
    ok "logs: watcher stop requested (kill it manually if needed)"
}

mod_logs_status() {
    applied=$(state_get "logs.applied")
    if [ "$applied" != "1" ]; then
        print_status N/A "logs: not hardened"
    else
        watcher=$(state_get "logs.watcher")
        iv=$(state_get "logs.interval")
        [ -x "$watcher" ] \
            && print_status OK "logs: watcher installed ($watcher), every ${iv}s" \
            || print_status PARTIAL "logs: watcher not executable"
    fi

    for f in "$MSG_LOG" "$VOICE_LOG"; do
        if [ -e "$f" ]; then
            sz=$(stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f" 2>/dev/null || echo 0)
            if [ "$sz" = "0" ]; then
                print_status OK "logs: $f present, size=0 (freshly cleared)"
            else
                print_status PARTIAL "logs: $f present, size=$sz (between clears — residual transcript possible)"
            fi
        else
            print_status N/A "logs: $f absent"
        fi
    done
}
