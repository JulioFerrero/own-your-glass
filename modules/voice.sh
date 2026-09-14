OYG_MOD_VOICE=1

# voice.sh — kill the LG Magic Remote's microphone pipeline.
#
# WHY THIS MODULE EXISTS (verified on the device)
# -----------------------------------------------
# The LG Magic Remote (HID_NAME="LGE MR25GA") ships its microphone audio
# NOT as an ALSA capture device, but as a Bluetooth HID raw stream
# arriving on /dev/hidraw0. Only the process `voiceinput_hidraw` reads
# that node. The pipeline that turns those bytes into text + logs is:
#
#     /dev/hidraw0 (HID_NAME=LGE MR25GA, mic audio)
#       --> voiceinput_hidraw
#       --> voiceinput          --> voiceconductor
#                                --> /tmp/app.voice.log
#                                --> /tmp/var/log/messages (NL_*, user_utterance)
#
# Neutralising the ALSA capture PCMs (what the `mic` module does) does
# NOT stop this path — there is no ALSA device involved. The mic button
# is just a HID key event on the same /dev/hidraw0 channel as every
# other remote button, and the audio bytes ride alongside it.
#
# WE DELIBERATELY DO NOT TOUCH /dev/hidraw*
# -----------------------------------------
# /dev/hidraw0 is the remote's raw HID channel. It carries BOTH:
#   * the mic button key event (KEY_VOICE)
#   * the mic audio bytes (consumed by voiceinput_hidraw)
# These share the same HID stack as the remote's pointer, scrollwheel,
# and every other button. Bind-mounting /dev/null over /dev/hidraw0
# would silence the microphone AND break every Magic Remote button —
# verified to be unacceptable (a TV with no working remote is much
# worse than a TV with a working microphone).
#
# The fix is to neutralise the consumer PROCESSES instead:
#   chmod 000 <binary>          — strip exec + read perms so even if a
#                                  respawner tries to exec, it can't
#   mount --bind /dev/null      — replace the binary itself so any
#     <binary>                    process that does exec() reads zeros
#                                  (and the kernel treats them as ENXIO
#                                  when launched as an executable)
#   pidof <name> + kill TERM/KILL — terminate any currently-running
#                                  instance of the consumer
#
# All three consumers together = the full mic-to-text path. Removing
# any one of them is sufficient to break capture+transcription; we
# remove all three so even if one is re-extracted by an update, the
# other two stay dead.
#
# EVIDENCE ON DEVICE
# ------------------
#   /dev/hidraw0  ->  HID_NAME=LGE MR25GA
#                    only reader: voiceinput_hidraw
#   Before       : voiceinput_hidraw / voiceinput / voiceconductor all
#                  running; mic button press triggers capture + logs
#                  (`NL_*`, `user_utterance`) within seconds.
#   After        : all three processes GONE after kill+bind; mic button
#                  press recorded only as
#                    lginput2 NL_BUTTON_CLICK {"remote_type":"LGE
#                    MR25GA","button_type":"KEY_VOICE"}
#                  in /tmp/var/log/messages; ZERO `user_utterance`,
#                  ZERO voice `NL_*` events; /tmp/app.voice.log stayed
#                  at 0 bytes; no respawn after 10 s; remote BUTTONS
#                  still work (input devices `LGE RCU`, `LGE M-RCU -
#                  Builtin [0..2]`, `LGE Simple Premium` remain and
#                  handle the rest of the HID channel); audio playback
#                  unaffected (`paplay rc=0`).
#
# Targets:
#   /usr/sbin/voiceinput_hidraw   — HID raw consumer; the source of the
#                                   mic audio stream (must come first)
#   /usr/sbin/voiceinput          — decoder/normaliser
#   /usr/sbin/voiceconductor      — orchestrator (writes app.voice.log
#                                   and the NL_* events to messages)

VOICE_TARGETS='
/usr/sbin/voiceinput_hidraw
/usr/sbin/voiceinput
/usr/sbin/voiceconductor
'

# State keys (per binary):
#   voice.<path>.prev    — original mode (octal string, e.g. "755")
#   voice.<path>.bound   — "1" if we bind-mounted /dev/null over it
# voice.applied          — "1" if harden completed (any binary bound)

# _mod_voice_is_bound <path>
#   Echo "1" if <path> is currently a mount point in /proc/self/mounts
#   or /proc/self/mountinfo. Echo "0" otherwise.
#
#   NOTE: we ASK whether the path is a mount point — we do NOT grep for
#   the literal "/dev/null". A bind mount of /dev/null is recorded as
#   root="/null", mountpoint=<path>, fstype=devtmpfs, source=devtmpfs
#   (verified on the device). Grepping for "/dev/null" therefore never
#   matches and every re-apply stacks another bind mount on top. This
#   is the same pitfall the `mic` module already fixed.
_mod_voice_is_bound() {
    p=$1
    if [ -r /proc/self/mountinfo ] \
        && awk -v t="$p" '$5 == t { f = 1 } END { exit !f }' /proc/self/mountinfo 2>/dev/null; then
        printf '1\n'
        return 0
    fi
    if [ -r /proc/mounts ] \
        && awk -v t="$p" '$2 == t { f = 1 } END { exit !f }' /proc/mounts 2>/dev/null; then
        printf '1\n'
        return 0
    fi
    printf '0\n'
    return 0
}

# _mod_voice_path_mode <path>
#   Echo the current mode of <path> as an octal string ("755" etc.),
#   or "" if stat fails or the path is absent.
_mod_voice_path_mode() {
    p=$1
    [ -e "$p" ] || { printf ''; return 0; }
    stat -c '%a' "$p" 2>/dev/null || stat -f '%Lp' "$p" 2>/dev/null || true
}

# _mod_voice_pids_for <process-name>
#   Echo PIDs of <process-name> (basename match), one per line, or empty
#   if none. Prefers `pidof` (busybox / procps), falls back to
#   `pgrep -x`. Tolerant of a missing tool: returns empty.
_mod_voice_pids_for() {
    proc=$1
    [ -z "$proc" ] && return 0
    if have pidof; then
        pidof "$proc" 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true
        return 0
    fi
    if have pgrep; then
        pgrep -x -- "$proc" 2>/dev/null || true
        return 0
    fi
    return 0
}

# _mod_voice_kill <process-name>
#   TERM, sleep, KILL if still alive. Echoes one line per PID actually
#   signalled ("pid <n> <signal>"). Returns 0 if the process is gone
#   afterwards, 1 otherwise. Caller captures output with command
#   substitution. No-op if no tool is available or the process is
#   absent.
_mod_voice_kill() {
    proc=$1
    [ -z "$proc" ] && return 0
    pids=$(_mod_voice_pids_for "$proc" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [ -z "$pids" ] && return 0
    for p in $pids; do
        if kill -TERM "$p" 2>/dev/null; then
            printf 'pid %s TERM\n' "$p"
        fi
    done
    sleep 1
    survivors=$(_mod_voice_pids_for "$proc" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    for p in $survivors; do
        if kill -KILL "$p" 2>/dev/null; then
            printf 'pid %s KILL\n' "$p"
        fi
    done
    sleep 1
    remaining=$(_mod_voice_pids_for "$proc")
    [ -z "$remaining" ] && return 0
    return 1
}

# _mod_voice_harden_one <path>
#   Apply the per-binary hardening steps (record mode, chmod 000, bind
#   /dev/null).
#
#   I/O contract (important — the caller uses command substitution):
#     stdout: a single status word "OK" / "FAIL" / "N/A" terminated by
#             a newline. THIS IS THE ONLY LINE that goes to the caller's
#             variable.
#     stderr: every human-readable diagnostic (ok/warn/err/DRY-RUN).
#             Stderr goes to the operator's terminal directly, so the
#             caller does not need to redirect anything — the captured
#             `status_line` is clean because command substitution only
#             captures stdout.
#   If both went to stdout, command substitution would capture the
#   diagnostics too and the outer `case "$status_line"` would match the
#   wrong word (the LAST line wins). The earlier version of this file
#   hit exactly that bug; the stderr split is the fix.
_mod_voice_harden_one() {
    path=$1
    if [ -z "$path" ]; then
        printf 'N/A\n'
        return 0
    fi

    if [ ! -e "$path" ]; then
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: chmod 000 %s\n' "$path" >&2
            printf 'DRY-RUN: mount --bind /dev/null %s\n' "$path" >&2
            printf '[dry-run] voice: %s not present here; planned: chmod 000 + mount --bind /dev/null\n' "$path" >&2
        else
            warn "voice: $path absent — skipping (not present on this system)" >&2
        fi
        printf 'N/A\n'
        return 0
    fi

    # Record the original mode once. If we already recorded one in a
    # previous harden run, reuse it so restore is exact.
    orig=$(state_get "voice.${path}.prev")
    if [ -z "$orig" ]; then
        orig=$(_mod_voice_path_mode "$path")
        [ -z "$orig" ] && orig="755"
        state_put "voice.${path}.prev" "$orig"
    fi

    # Idempotency: skip if already a mount point. We ask "is this a
    # mount point?" — see _mod_voice_is_bound for why we do NOT grep
    # for the literal /dev/null.
    if [ "$(_mod_voice_is_bound "$path")" = "1" ]; then
        ok "voice: $path already bind-mounted to /dev/null (idempotent)" >&2
        state_put "voice.${path}.bound" "1"
        printf 'OK\n'
        return 0
    fi

    # Strip exec + read perms first. A process that holds an open fd
    # cannot bypass the bind-mount, but stripping perms is a cheap
    # belt-and-braces on top of the bind.
    if run chmod 000 "$path" 2>/dev/null; then
        ok "voice: chmod 000 $path (was $orig)" >&2
    else
        warn "voice: chmod 000 on $path denied (will still bind-mount)" >&2
    fi

    # Replace the binary with /dev/null. Any exec() now reads zeros
    # and fails; any open() returns ENXIO.
    if run mount --bind /dev/null "$path" 2>/dev/null; then
        ok "voice: mount --bind /dev/null $path (consumer neutralised)" >&2
        state_put "voice.${path}.bound" "1"
        printf 'OK\n'
        return 0
    fi

    err "voice: mount --bind /dev/null $path failed" >&2
    state_drop "voice.${path}.bound"
    printf 'FAIL\n'
    return 1
}

mod_voice_harden() {
    require_root
    ensure_dirs

    rc=0
    ok_count=0
    fail_count=0

    # Run one binary at a time (no pipe into `while` — we need ok_count
    # to survive across iterations; the per-binary work happens in a
    # helper that writes the per-path diagnostics to stderr and a
    # single status word to stdout; command substitution captures
    # only the stdout status word).
    for path in $VOICE_TARGETS; do
        [ -z "$path" ] && continue
        # Skip pure-comment / blank lines from the multi-line string.
        case "$path" in
            ""|\#*) continue ;;
        esac

        status_line=$(_mod_voice_harden_one "$path")
        case "$status_line" in
            OK)   ok_count=$((ok_count + 1)) ;;
            FAIL) fail_count=$((fail_count + 1)); rc=1 ;;
        esac
    done

    # Termination pass. Done AFTER all binds so a process that tries to
    # re-exec one of the binaries as it dies hits the bind immediately
    # (and the chmod 000 makes even the loader fail to map it).
    # We kill each binary's basename regardless of whether the bind
    # succeeded for that particular path, because the process names
    # match the basenames on this device (verified:
    # /usr/sbin/voiceinput_hidraw runs as PID <n> with comm
    # "voiceinput_hidraw"; likewise voiceinput, voiceconductor).
    for path in $VOICE_TARGETS; do
        [ -z "$path" ] && continue
        case "$path" in
            ""|\#*) continue ;;
        esac
        proc=$(basename "$path")
        if [ "$OYG_DRY_RUN" = "1" ]; then
            # In dry-run, always show the planned kill so the operator
            # can see the full plan even on a dev box that has none of
            # these binaries (and therefore nothing to actually kill).
            printf 'DRY-RUN: kill %s (TERM then KILL if needed)\n' "$proc"
            continue
        fi
        # In a real run, only kill if the binary is present (else the
        # process can't exist on this box anyway, and we'd be hunting a
        # process by a name that nothing on the box uses).
        [ -e "$path" ] || continue
        out=$(_mod_voice_kill "$proc")
        if [ -n "$out" ]; then
            printf '%s\n' "$out" | while IFS= read -r line; do
                [ -n "$line" ] && ok "voice: $proc $line"
            done
        fi
    done

    if [ "$ok_count" -gt 0 ]; then
        state_put "voice.applied" "1"
    fi

    return $rc
}

mod_voice_restore() {
    require_root

    rc=0
    for path in $VOICE_TARGETS; do
        [ -z "$path" ] && continue
        case "$path" in
            ""|\#*) continue ;;
        esac

        bound=$(state_get "voice.${path}.bound")
        orig=$(state_get "voice.${path}.prev")

        if [ "$bound" = "1" ]; then
            # Verify it is OURS — i.e. we recorded binding it. The
            # mountinfo check is belt-and-braces; we never umount
            # something we didn't mount.
            if [ "$(_mod_voice_is_bound "$path")" = "1" ]; then
                if run umount "$path" 2>/dev/null; then
                    ok "voice: umounted $path"
                else
                    warn "voice: could not umount $path — manual cleanup required"
                    rc=1
                fi
            else
                warn "voice: $path was recorded as bound but is no longer mounted — leaving alone"
            fi
            state_drop "voice.${path}.bound"
        fi

        if [ -n "$orig" ] && [ "$orig" != "0" ] && [ -e "$path" ]; then
            if run chmod "$orig" "$path" 2>/dev/null; then
                ok "voice: $path mode restored to $orig"
            else
                warn "voice: could not restore mode on $path to $orig"
                rc=1
            fi
        fi
        state_drop "voice.${path}.prev"
    done

    state_drop "voice.applied"
    return $rc
}

# Status helper: for one binary, decide OK / FAIL / N/A.
# Prints nothing; sets `voice_one_state` and `voice_one_detail`.
_mod_voice_check_one() {
    path=$1
    name=$(basename "$path")

    if [ ! -e "$path" ]; then
        voice_one_state=N/A
        voice_one_detail="voice: $name ($path) absent on this system"
        return
    fi

    # Real check: is the binary a mount point right now?
    if [ "$(_mod_voice_is_bound "$path")" = "1" ]; then
        # And is the process gone?
        proc=$(basename "$path")
        still=$(_mod_voice_pids_for "$proc")
        if [ -z "$still" ]; then
            voice_one_state=OK
            voice_one_detail="voice: $name ($path) bound to /dev/null, process gone"
        else
            voice_one_state=FAIL
            voice_one_detail="voice: $name ($path) bound but process still running (pids: $still)"
        fi
        return
    fi

    voice_one_state=FAIL
    voice_one_detail="voice: $name ($path) NOT bound to /dev/null — pipeline live"
}

mod_voice_status() {
    any_fail=0
    any_ok=0
    for path in $VOICE_TARGETS; do
        [ -z "$path" ] && continue
        case "$path" in
            ""|\#*) continue ;;
        esac
        _mod_voice_check_one "$path"
        print_status "$voice_one_state" "$voice_one_detail"
        case "$voice_one_state" in
            OK)   any_ok=1 ;;
            FAIL) any_fail=1 ;;
        esac
    done

    if [ "$any_ok" = "1" ] && [ "$any_fail" = "1" ]; then
        warn "voice: PARTIAL — some consumers bound, some not"
        return 1
    elif [ "$any_fail" = "1" ]; then
        return 1
    fi
    return 0
}
