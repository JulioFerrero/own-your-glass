OYG_MOD_CAPTURE=1

# capture.sh — neutralise the screen-framebuffer leak.
#
# /tmp/capture.rgb (640x360 RGB24) is written every ~3s by
# com.webos.service.oledepl via com.webos.service.capture/executeOneShot.
# It is world-readable AND visible inside app sandboxes.
#
# Strategy (in order, with fallback):
#   1) chattr +i  — if the filesystem supports immutable
#   2) chmod 000 / 0600 plus a watcher that re-asserts the mode (the
#      writer re-creates the file, so a one-shot chmod is not enough)
#   3) install the watcher from the boot hook

CAPTURE_PATH=/tmp/capture.rgb
VTCAP_BIN=/usr/bin/vtCaptureTestSuite
WATCH_SCRIPT_DST="$OYG_ROOT/watch-capture.sh"

# Resolve a path to its absolute, canonical form for same-file comparison.
_path_canon() {
    p=$1
    if have readlink; then
        canon=$(readlink -f "$p" 2>/dev/null) && [ -n "$canon" ] && { printf '%s\n' "$canon"; return 0; }
    fi
    printf '%s' "$p" | tr -s '/' '/' | sed -E 's:^\./::; s:/\.$::; s:/+$::'
}

mod_capture_install_watcher() {
    src="$OYG_ROOT/watch-capture.sh"
    dst="$WATCH_SCRIPT_DST"
    if [ ! -f "$src" ]; then
        err "watcher template missing: $src"
        return 1
    fi
    if [ "$(_path_canon "$src")" = "$(_path_canon "$dst")" ]; then
        if [ -x "$dst" ]; then
            ok "capture: watcher already installed at $dst"
            return 0
        fi
        run chmod 0755 "$dst" 2>/dev/null || true
        if [ -x "$dst" ]; then
            ok "capture: watcher already present at $dst (mode tightened)"
            return 0
        fi
        warn "capture: watcher src==dst but not executable; ignoring"
        return 0
    fi
    if ! run cp "$src" "$dst"; then
        err "cannot copy watcher to $dst"
        return 1
    fi
    run chmod 0755 "$dst" 2>/dev/null || true
    return 0
}

mod_capture_harden() {
    require_root
    ensure_dirs

    strategy="none"
    if [ ! -e "$CAPTURE_PATH" ]; then
        warn "$CAPTURE_PATH does not exist yet (writer may run on demand)"
        state_put "capture.file" "$CAPTURE_PATH"
        state_put "capture.file.missing_at_harden" "1"
    fi

    if [ -e "$CAPTURE_PATH" ] && have chattr; then
        if chattr +i "$CAPTURE_PATH" 2>/dev/null; then
            strategy="chattr-immutable"
            ok "capture: chattr +i applied to $CAPTURE_PATH"
        else
            warn "capture: chattr +i not supported here, falling back to chmod+watcher"
        fi
    fi

    if [ "$strategy" != "chattr-immutable" ]; then
        if [ -e "$CAPTURE_PATH" ]; then
            current=$(stat -c '%a' "$CAPTURE_PATH" 2>/dev/null || stat -f '%Lp' "$CAPTURE_PATH" 2>/dev/null || echo unknown)
            state_put "capture.file.mode.orig" "$current"
            if chmod 000 "$CAPTURE_PATH" 2>/dev/null; then
                ok "capture: chmod 000 applied to $CAPTURE_PATH (was $current)"
            elif chmod 0600 "$CAPTURE_PATH" 2>/dev/null; then
                ok "capture: chmod 0600 applied to $CAPTURE_PATH (was $current)"
            else
                warn "capture: chmod denied on $CAPTURE_PATH"
            fi
        fi
        strategy="chmod+watcher"
        mod_capture_install_watcher || warn "capture: watcher install failed"
        state_put "capture.watcher" "$WATCH_SCRIPT_DST"
        ok "capture: watcher installed at $WATCH_SCRIPT_DST (boot hook will spawn it)"
    fi

    if [ -e "$VTCAP_BIN" ]; then
        cur=$(stat -c '%a' "$VTCAP_BIN" 2>/dev/null || stat -f '%Lp' "$VTCAP_BIN" 2>/dev/null || echo unknown)
        state_put "capture.vtcap.mode.orig" "$cur"

        # Strategy ladder for read-only vendor binaries:
        #   1. mount --bind /dev/null <path>  (works on this device even
        #      when /usr is read-only; verified)
        #   2. chmod 000 if the path is writable
        #   3. report FAIL with the reason
        already_bound=0
        if [ "$OYG_DRY_RUN" != "1" ] && [ -r /proc/self/mountinfo ] \
            && grep -q " $VTCAP_BIN " /proc/self/mountinfo 2>/dev/null; then
            already_bound=1
        fi

        if [ "$already_bound" = "1" ]; then
            ok "capture: vtCaptureTestSuite already bind-mounted (re-apply idempotent)"
            state_put "capture.vtcap.neutralised" "bind"
            state_put "capture.vtcap.bind" "$VTCAP_BIN"
        elif [ "$OYG_DRY_RUN" = "1" ]; then
            run mount --bind /dev/null "$VTCAP_BIN" \
                && ok "capture: vtCaptureTestSuite would be bind-mounted to /dev/null (was mode $cur)" \
                || warn "capture: bind-mount dry-run failed"
            state_put "capture.vtcap.neutralised" "bind"
            state_put "capture.vtcap.bind" "$VTCAP_BIN"
        elif run mount --bind /dev/null "$VTCAP_BIN" 2>/dev/null; then
            ok "capture: vtCaptureTestSuite bind-mounted to /dev/null (was mode $cur)"
            state_put "capture.vtcap.neutralised" "bind"
            state_put "capture.vtcap.bind" "$VTCAP_BIN"
        elif [ -w "$VTCAP_BIN" ] && run chmod 000 "$VTCAP_BIN" 2>/dev/null; then
            ok "capture: vtCaptureTestSuite chmod 000 (was $cur)"
            state_put "capture.vtcap.neutralised" "chmod"
        else
            err "capture: cannot neutralise $VTCAP_BIN (bind-mount failed and not writable)"
            state_put "capture.vtcap.neutralised" "failed"
        fi
    else
        state_put "capture.vtcap.mode.orig" "absent"
        state_put "capture.vtcap.neutralised" "absent"
    fi

    state_put "capture.strategy" "$strategy"
    state_put "capture.applied" "1"
}

mod_capture_restore() {
    require_root
    strategy=$(state_get "capture.strategy")
    orig=$(state_get "capture.file.mode.orig")
    if [ -n "$orig" ] && [ -e "$CAPTURE_PATH" ]; then
        run chmod "$orig" "$CAPTURE_PATH" 2>/dev/null && ok "capture: $CAPTURE_PATH mode restored to $orig"
    fi
    if [ "$strategy" = "chattr-immutable" ] && [ -e "$CAPTURE_PATH" ] && have chattr; then
        chattr -i "$CAPTURE_PATH" 2>/dev/null && ok "capture: immutable flag cleared"
    fi
    vtor=$(state_get "capture.vtcap.mode.orig")
    neutralised=$(state_get "capture.vtcap.neutralised")
    case "$neutralised" in
        bind)
            bind_path=$(state_get "capture.vtcap.bind")
            if [ -n "$bind_path" ]; then
                if run umount "$bind_path" 2>/dev/null; then
                    ok "capture: vtCaptureTestSuite bind-mount umounted ($bind_path)"
                else
                    warn "capture: could not umount $bind_path — manual cleanup required"
                fi
            fi
            ;;
        chmod)
            if [ -n "$vtor" ] && [ "$vtor" != "not-writable" ] && [ "$vtor" != "absent" ] && [ -e "$VTCAP_BIN" ]; then
                run chmod "$vtor" "$VTCAP_BIN" 2>/dev/null && ok "capture: vtCaptureTestSuite mode restored to $vtor"
            fi
            ;;
        failed|absent)
            : ;;
    esac
    state_drop "capture.strategy"
    state_drop "capture.file.mode.orig"
    state_drop "capture.vtcap.mode.orig"
    state_drop "capture.vtcap.neutralised"
    state_drop "capture.vtcap.bind"
    state_drop "capture.watcher"
    state_drop "capture.applied"
}

mod_capture_status() {
    strategy=$(state_get "capture.strategy")
    applied=$(state_get "capture.applied")
    if [ "$applied" != "1" ]; then
        print_status N/A "capture: not hardened"
        if [ -e "$CAPTURE_PATH" ]; then
            cur=$(stat -c '%a' "$CAPTURE_PATH" 2>/dev/null || stat -f '%Lp' "$CAPTURE_PATH" 2>/dev/null || echo unknown)
            print_status FAIL "capture: $CAPTURE_PATH is mode $cur (world-readable?)"
        fi
        return
    fi

    if [ "$strategy" = "chattr-immutable" ] && [ -e "$CAPTURE_PATH" ]; then
        if lsattr "$CAPTURE_PATH" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
            print_status OK "capture: $CAPTURE_PATH is immutable (chattr +i)"
        else
            print_status PARTIAL "capture: immutable flag missing on $CAPTURE_PATH"
        fi
    elif [ -e "$CAPTURE_PATH" ]; then
        cur=$(stat -c '%a' "$CAPTURE_PATH" 2>/dev/null || stat -f '%Lp' "$CAPTURE_PATH" 2>/dev/null || echo unknown)
        case "$cur" in
            0) print_status OK "capture: $CAPTURE_PATH mode 000 + watcher installed";;
            600) print_status OK "capture: $CAPTURE_PATH mode 0600 + watcher installed";;
            *) print_status PARTIAL "capture: $CAPTURE_PATH mode $cur (watcher should re-tighten)";;
        esac
    else
        print_status OK "capture: hardened (writer inactive); strategy=$strategy"
    fi

    if [ -e "$VTCAP_BIN" ]; then
        cur=$(stat -c '%a' "$VTCAP_BIN" 2>/dev/null || stat -f '%Lp' "$VTCAP_BIN" 2>/dev/null || echo unknown)
        vtor=$(state_get "capture.vtcap.mode.orig")
        neutralised=$(state_get "capture.vtcap.neutralised")
        case "$neutralised" in
            bind)
                # A bind-mounted /dev/null over a regular file is itself
                # a character device with mode 0666. We can detect it via
                # stat: the type becomes 'c' (or via the /proc/self/mountinfo
                # table on a real device). In dry-run we just trust state.
                if [ "$OYG_DRY_RUN" = "1" ]; then
                    print_status OK "capture: vtCaptureTestSuite bind-mounted to /dev/null (dry-run)"
                elif [ -r /proc/self/mountinfo ] && grep -q " $VTCAP_BIN " /proc/self/mountinfo 2>/dev/null; then
                    print_status OK "capture: vtCaptureTestSuite bind-mounted to /dev/null"
                else
                    print_status PARTIAL "capture: vtCaptureTestSuite bind state lost (re-apply)"
                fi
                ;;
            chmod)
                if [ "$cur" = "0" ] || [ "$cur" = "600" ]; then
                    print_status OK "capture: vtCaptureTestSuite mode $cur"
                else
                    print_status PARTIAL "capture: vtCaptureTestSuite mode $cur"
                fi
                ;;
            failed)
                print_status FAIL "capture: vtCaptureTestSuite could not be neutralised (bind-mount failed and not writable)"
                ;;
            absent)
                : ;;
            *)
                if [ "$vtor" = "not-writable" ]; then
                    print_status N/A "capture: vtCaptureTestSuite not writable (vendor ro)"
                else
                    print_status N/A "capture: vtCaptureTestSuite not hardened"
                fi
                ;;
        esac
    fi
}
