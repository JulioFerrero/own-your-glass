OYG_MOD_REMOTEONE=1

# remoteone.sh — ensure the vendor remote-support gate never exists.
#
# F18/F30: RemoteOne / remote support on webOS TVs is gated by the
# existence of a directory/file under /mnt/lg/cmn_data/remoteDebug/.
# If it exists, LG support (or anyone with the right channel) can dial in.
#
# We do NOT delete it (that would also defeat the user's intent — they
# may want a "RemoteOne is enabled" report). We:
#   - report existence loudly
#   - if absent, confirm absence as the hardened state
#   - with OYG_AGGRESSIVE=1, also tighten /mnt/lg/cmn_data itself

REMOTEDEBUG=/mnt/lg/cmn_data/remoteDebug
CMN_DATA=/mnt/lg/cmn_data

mod_remoteone_harden() {
    require_root
    ensure_dirs
    state_put "remoteone.applied" "1"

    if [ -e "$REMOTEDEBUG" ]; then
        state_put "remoteone.gate.present" "1"
        warn "remoteone: $REMOTEDEBUG EXISTS — remote support gate is currently active"
        warn "remoteone: run `oyg restore` only if you trust the vendor channel"
        warn "remoteone: this tool intentionally does NOT remove the gate (owners must decide)"
        return 0
    fi

    ok "remoteone: $REMOTEDEBUG absent (hardened)"

    if [ "${OYG_AGGRESSIVE:-0}" = "1" ]; then
        if [ -d "$CMN_DATA" ] && [ -w "$CMN_DATA" ]; then
            cur=$(stat -c '%a' "$CMN_DATA" 2>/dev/null || stat -f '%Lp' "$CMN_DATA" 2>/dev/null || echo unknown)
            state_put "remoteone.cmndata.prev" "$cur"
            run chmod 0755 "$CMN_DATA" && ok "remoteone: $CMN_DATA -> 0755 (was $cur)"
        else
            warn "remoteone: $CMN_DATA not writable"
            state_put "remoteone.cmndata.prev" "not-writable"
        fi
    else
        warn "remoteone: chmod $CMN_DATA requires OYG_AGGRESSIVE=1"
    fi
}

mod_remoteone_restore() {
    require_root
    state_drop "remoteone.gate.present"
    state_drop "remoteone.applied"
    prev=$(state_get "remoteone.cmndata.prev")
    if [ -n "$prev" ] && [ "$prev" != "not-writable" ] && [ -d "$CMN_DATA" ]; then
        run chmod "$prev" "$CMN_DATA" && ok "remoteone: $CMN_DATA restored to $prev"
    fi
    state_drop "remoteone.cmndata.prev"
}

mod_remoteone_status() {
    if [ -e "$REMOTEDEBUG" ]; then
        lsout=$(ls -ld "$REMOTEDEBUG" 2>/dev/null || echo "?")
        print_status FAIL "remoteone: $REMOTEDEBUG EXISTS — vendor remote-support gate active"
        print_status FAIL "remoteone: $lsout"
    else
        applied=$(state_get "remoteone.applied")
        if [ "$applied" = "1" ]; then
            print_status OK "remoteone: $REMOTEDEBUG absent"
        else
            print_status N/A "remoteone: gate absent (not explicitly hardened)"
        fi
    fi

    if [ "${OYG_AGGRESSIVE:-0}" = "1" ] && [ -d "$CMN_DATA" ]; then
        cur=$(stat -c '%a' "$CMN_DATA" 2>/dev/null || stat -f '%Lp' "$CMN_DATA" 2>/dev/null || echo unknown)
        case "$cur" in
            755|750) print_status OK "remoteone: $CMN_DATA mode $cur";;
            *) print_status PARTIAL "remoteone: $CMN_DATA mode $cur";;
        esac
    fi
}
