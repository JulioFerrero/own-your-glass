OYG_MOD_PERMS=1

# perms.sh — tighten modes on world-writable, root-executed code paths
# (F16: webOSbrew hbchannel service; F17: com.webos.ghp.runtime).
# Invasive: may break webOSbrew updates + Google Home runtime — the user
# must opt in via OYG_AGGRESSIVE=1.
# Details, verification history and findings: docs/FINDINGS.md (F16, F17)

PERMS_TARGETS='
/media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service:0755
/media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service/service.js:0644
/media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service/startup.sh:0755
'

PERMS_DIRS='
/media/system/apps/usr/palm/services/com.webos.ghp.runtime/lib:0755
/media/system/apps/usr/palm/services/com.webos.ghp.runtime/conf:0755
'

PERMS_LIB_GLOB='/media/system/apps/usr/palm/services/com.webos.ghp.runtime/lib/*'

mod_perms_harden() {
    require_root
    if [ "${OYG_AGGRESSIVE:-0}" != "1" ]; then
        warn "perms: requires OYG_AGGRESSIVE=1 (changing vendor + webOSbrew code paths)"
        warn "perms: refusing to chmod without explicit opt-in"
        # NOTE: do NOT touch `perms.applied`. A skip must not clobber
        # another module's .applied key, and it must not lie about
        # reality. The status function verifies reality directly
        # (stat the actual paths), so a skipped run produces no
        # observable change.
        return 0
    fi

    ensure_dirs
    state_put "perms.applied" "1"

    printf '%s\n' "$PERMS_TARGETS" | while IFS=: read -r path mode; do
        path=$(trim "$path"); mode=$(trim "$mode")
        [ -z "$path" ] && continue
        if [ ! -e "$path" ]; then
            warn "perms: $path does not exist — skipping"
            continue
        fi
        cur=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null || echo unknown)
        state_put "perms.${path}.prev" "$cur"
        if run chmod "$mode" "$path"; then
            ok "perms: $path -> $mode (was $cur)"
        else
            err "perms: chmod $mode $path failed (read-only fs?)"
        fi
    done

    printf '%s\n' "$PERMS_DIRS" | while IFS=: read -r path mode; do
        path=$(trim "$path"); mode=$(trim "$mode")
        [ -z "$path" ] && continue
        if [ ! -d "$path" ]; then
            warn "perms: $path not a dir — skipping"
            continue
        fi
        cur=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null || echo unknown)
        state_put "perms.${path}.prev" "$cur"
        run chmod "$mode" "$path" \
            && ok "perms: dir $path -> $mode (was $cur)" \
            || err "perms: chmod $mode $path failed"
    done

    if [ -d /media/system/apps/usr/palm/services/com.webos.ghp.runtime/lib ]; then
        for f in /media/system/apps/usr/palm/services/com.webos.ghp.runtime/lib/*; do
            [ -e "$f" ] || continue
            cur=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || echo unknown)
            state_put "perms.${f}.prev" "$cur"
            run chmod 0644 "$f" \
                && ok "perms: $f -> 0644 (was $cur)" \
                || warn "perms: chmod 0644 $f failed"
        done
    fi
}

mod_perms_restore() {
    require_root
    if [ "${OYG_AGGRESSIVE:-0}" != "1" ]; then
        warn "perms: OYG_AGGRESSIVE!=1, nothing to restore"
        return 0
    fi

    [ -r "$OYG_STATE" ] || return 0
    awk -F= '$1 ~ /^perms\./ && $1 ~ /\.prev$/ {print $1}' "$OYG_STATE" | while IFS= read -r key; do
        [ -z "$key" ] && continue
        path=$(printf '%s' "$key" | sed 's/^perms\.//; s/\.prev$//')
        prev=$(state_get "$key")
        [ -z "$prev" ] && continue
        if [ -e "$path" ]; then
            run chmod "$prev" "$path" && ok "perms: $path restored to $prev"
        fi
        state_drop "$key"
    done
    state_drop "perms.applied"
}

# _mod_perms_not_writable <path>
#   Echo "1" if <path> exists AND its mode has no group/other write
#   bit (i.e. & 022 == 0). Echo "0" otherwise. Echo "N/A" if the path
#   is absent (so the caller can decide whether to skip).
#
#   We do NOT trust the `perms.applied` state key. The brief observes
#   that key gets clobbered to "0" / "skipped" by later runs of other
#   modules. The truth is in the file mode bits on disk.
_mod_perms_not_writable() {
    p=$1
    [ -e "$p" ] || { printf 'N/A\n'; return 0; }
    cur=$(stat -c '%a' "$p" 2>/dev/null || stat -f '%Lp' "$p" 2>/dev/null || echo unknown)
    [ "$cur" = "unknown" ] && { printf 'N/A\n'; return 0; }
    # mode is an octal string; we want `& 022 == 0`. Strip any leading
    # zero and use shell arithmetic. If the path is a directory the
    # `g+w` / `o+w` check still applies — we want the dir not writable
    # by group or other.
    case "$cur" in
        *[!0-7]*) printf 'N/A\n'; return 0 ;; # non-octal, refuse to judge
    esac
    dec=$((8#$cur))
    if [ $((dec & 022)) -eq 0 ]; then
        printf '1\n'
    else
        printf '0\n'
    fi
}

mod_perms_status() {
    # Reality check, NOT a state-key check. The previous implementation
    # short-circuited on `perms.applied`; that key was being clobbered
    # to "0" or "skipped" by other modules' runs, which made `oyg
    # status` report "not applied" even when the actual files were
    # mode 0755 / 0644. We now stat each path directly: OK if its
    # mode has no group or other write bit, FAIL otherwise, N/A if
    # the path is absent.

    printf '%s\n' "$PERMS_TARGETS" | while IFS=: read -r path mode; do
        path=$(trim "$path"); mode=$(trim "$mode")
        [ -z "$path" ] && continue
        nw=$(_mod_perms_not_writable "$path")
        case "$nw" in
            1)
                print_status OK "perms: $path not group/other-writable"
                ;;
            0)
                cur=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null || echo unknown)
                print_status FAIL "perms: $path mode $cur is group/other-writable"
                ;;
            *)
                print_status N/A "perms: $path not present"
                ;;
        esac
    done

    printf '%s\n' "$PERMS_DIRS" | while IFS=: read -r path mode; do
        path=$(trim "$path"); mode=$(trim "$mode")
        [ -z "$path" ] && continue
        nw=$(_mod_perms_not_writable "$path")
        case "$nw" in
            1)
                print_status OK "perms: dir $path not group/other-writable"
                ;;
            0)
                cur=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null || echo unknown)
                print_status FAIL "perms: dir $path mode $cur is group/other-writable"
                ;;
            *)
                print_status N/A "perms: dir $path not present"
                ;;
        esac
    done

    # The lib/* files inside com.webos.ghp.runtime/lib are also tightened
    # (chmod 0644) by harden. We verify the same way.
    if [ -d /media/system/apps/usr/palm/services/com.webos.ghp.runtime/lib ]; then
        for f in /media/system/apps/usr/palm/services/com.webos.ghp.runtime/lib/*; do
            [ -e "$f" ] || continue
            nw=$(_mod_perms_not_writable "$f")
            case "$nw" in
                1)
                    print_status OK "perms: $f not group/other-writable"
                    ;;
                0)
                    cur=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || echo unknown)
                    print_status FAIL "perms: $f mode $cur is group/other-writable"
                    ;;
            esac
        done
    fi
}
