OYG_MOD_MIC=1

# mic.sh — neutralise the microphone capture path.
#
# WHY THE OLD amixer APPROACH WAS REMOVED
# ---------------------------------------
# The previous module tried `amixer` controls (Capture, Mic, numid=628 /
# "Adc Open") on card 0. On this device the writable-by-us control is
# driver-owned and returns "Operation not permitted" when closed, so the
# module could only ever report PARTIAL. The driver does not expose a
# user-mutable mute for the capture gain. amixer is therefore a dead end
# on this hardware — kept here only as a comment for posterity.
#
# THE NEW APPROACH (verified working on the device)
# -------------------------------------------------
# We cut the pipe at the device-node level. Every ALSA capture PCM is a
# device node under /dev/snd named pcmC<card>D<dev>c. Bind-mounting
# /dev/null over each one makes every open() on that PCM return ENXIO /
# "Inappropriate ioctl for device". arecord therefore produces 0 bytes
# (or fails) and no audio reaches user space. Playback nodes
# (pcmC*Dp) are deliberately left alone — playback is preserved.
#
# Evidence on the device:
#   BEFORE: arecord -D hw:0,10 ... | wc -c   ->  64000 bytes
#   APPLY : chmod 000 /dev/snd/pcmC0D10c
#           mount --bind /dev/null /dev/snd/pcmC0D10c
#   AFTER : arecord -D hw:0,10 ...
#           -> "arecord: main:831: audio open error: Inappropriate ioctl for device"
#           -> 0 bytes
#   PLAYBACK: paplay -d pcm_output <file>  -> rc=0   (unaffected)
#
# The capture nodes on this device are:
#   pcmC0D10c  pcmC0D11c  pcmC0D12c
#   pcmC0D13c  pcmC0D14c  pcmC1D0c
# Playback nodes (NEVER touched): pcmC0D0p … pcmC0D7p.

# State keys (per node):
#   mic.node.<basename>.mode.orig  — original mode (e.g. "660")
#   mic.node.<basename>.bound      — "1" if we bind-mounted /dev/null over it
#   mic.applied                    — "1" if harden completed (any node bound)

# mod_mic_list_capture_nodes
#   Print all capture PCM device-node paths under /dev/snd, one per line.
#   Dynamic enumeration takes precedence over any hardcoded fallback:
#     1) walk /dev/snd/pcmC* and select names ending in 'c' (capture)
#     2) cross-check with /proc/asound/pcm lines whose INFO column
#        contains "capture" — only nodes that appear in BOTH sources
#        are kept (so we never accidentally target a playback node if
#        the kernel naming is unusual)
#     3) if neither yields anything, fall back to the known device
#        capture list, so the module still works on dev machines
#        that don't have /dev/snd (and so a fresh device with no
#        /proc/asound/pcm is still covered).
mod_mic_list_capture_nodes() {
    _mic_tmp=${OYG_TMPDIR:-/tmp}
    found_dynamic=0
    # Source 1: device nodes in /dev/snd ending in 'c'
    if [ -d /dev/snd ]; then
        for n in /dev/snd/pcmC*c; do
            [ -e "$n" ] || continue
            case "$n" in
                *c) printf '%s\n' "$n" ;;
            esac
        done >"$_mic_tmp/mic.devs" 2>/dev/null
    fi

    # Source 2: /proc/asound/pcm — lines look like:
    #   00-00: ... : playback 1 : capture 1
    # A node is a capture node iff its line has "capture" in the INFO
    # column after the second ':' and the PCM info contains the device
    # card+device numbers we can map to a node path. The numeric field
    # is zero-padded ("00-10") but /dev/snd uses the unpadded form
    # ("pcmC0D10c"), so we strip leading zeros before composing the path.
    if [ -n "${OYG_PROC_ASOUND_PCM:-}" ] && [ -r "$OYG_PROC_ASOUND_PCM" ]; then
        _pcm_src=$OYG_PROC_ASOUND_PCM
    elif [ -r /proc/asound/pcm ]; then
        _pcm_src=/proc/asound/pcm
    else
        _pcm_src=
    fi
    if [ -n "$_pcm_src" ]; then
        awk -F': ' '
            /^ *[0-9]+-[0-9]+:/ {
                split($1, hd, "-");
                card = hd[1] + 0; dev  = hd[2] + 0;
                rest = $0; sub(/^[^:]*:[^:]*: /, "", rest);
                if (rest ~ /capture/) printf "/dev/snd/pcmC%dD%dc\n", card, dev;
            }
        ' "$_pcm_src" >"$_mic_tmp/mic.proc" 2>/dev/null
    fi

    # Cross-check: keep a node only if it appears in BOTH sources.
    # If one source is empty (e.g. dev box with no /dev/snd), use the
    # other source alone. If both are empty, fall back to the hardcoded
    # list — and tag the fallback so the caller knows the dynamic
    # enumeration was unavailable.
    have_dev=0; have_proc=0
    [ -s "$_mic_tmp/mic.devs" ]  && have_dev=1
    [ -s "$_mic_tmp/mic.proc" ] && have_proc=1

    if [ "$have_dev" = "1" ] && [ "$have_proc" = "1" ]; then
        # Both: intersection, dynamic wins.
        while IFS= read -r n; do
            [ -z "$n" ] && continue
            if grep -Fxq "$n" "$_mic_tmp/mic.proc"; then
                printf '%s\n' "$n"
                found_dynamic=1
            fi
        done <"$_mic_tmp/mic.devs"
    elif [ "$have_dev" = "1" ]; then
        cat "$_mic_tmp/mic.devs"
        found_dynamic=1
    elif [ "$have_proc" = "1" ]; then
        cat "$_mic_tmp/mic.proc"
        found_dynamic=1
    else
        # Fallback list, only used when nothing is enumerable on the box.
        # This is the device's known capture-node list. Dynamic wins when
        # ANY source produces output, so this is dead code in production.
        cat <<'EOF'
/dev/snd/pcmC0D10c
/dev/snd/pcmC0D11c
/dev/snd/pcmC0D12c
/dev/snd/pcmC0D13c
/dev/snd/pcmC0D14c
/dev/snd/pcmC1D0c
EOF
    fi

    if [ "$found_dynamic" = "1" ]; then
        return 0
    fi
    return 1
}

# mod_mic_node_to_alsa <node-path>
#   Map /dev/snd/pcmC<card>D<dev>c  ->  hw:<card>,<dev>
#   Echoes the ALSA device string. Echoes nothing if the input doesn't
#   match the expected PCM node pattern.
mod_mic_node_to_alsa() {
    n=$1
    case "$n" in
        /dev/snd/pcmC[0-9]*D[0-9]*c)
            base=$(basename "$n")
            # pcmC0D10c -> card=0 dev=10
            card=$(printf '%s' "$base" | sed -nE 's/^pcmC([0-9]+)D([0-9]+)c$/\1/p')
            dev=$(printf  '%s' "$base" | sed -nE 's/^pcmC([0-9]+)D([0-9]+)c$/\2/p')
            if [ -n "$card" ] && [ -n "$dev" ]; then
                printf 'hw:%s,%s\n' "$card" "$dev"
                return 0
            fi
            ;;
    esac
    return 1
}

# mod_mic_is_bound <node-path>
#   Echo "1" if /proc/self/mounts shows <node> currently bind-mounted
#   to /dev/null. Echo "0" otherwise. Never empty.
mod_mic_is_bound() {
    n=$1
    # NOTE: do NOT grep for the literal "/dev/null" — a bind mount of /dev/null
    # is recorded as root="/null", mountpoint=<node>, fstype=devtmpfs,
    # source=devtmpfs, so that grep never matched and every re-apply stacked
    # another bind mount. Detect a bind by asking whether <node> is a MOUNT
    # POINT at all: field 2 in /proc/mounts, field 5 in /proc/self/mountinfo.
    if [ -r /proc/self/mountinfo ] && \
        awk -v t="$n" '$5 == t { f = 1 } END { exit !f }' /proc/self/mountinfo 2>/dev/null; then
        printf '1\n'
        return 0
    fi
    if [ -r /proc/mounts ] && \
        awk -v t="$n" '$2 == t { f = 1 } END { exit !f }' /proc/mounts 2>/dev/null; then
        printf '1\n'
        return 0
    fi
    printf '0\n'
    return 0
}

# mod_mic_node_mode <node-path>
#   Echo the current mode of <node> as an octal string ("660" etc.),
#   or "" if stat fails.
mod_mic_node_mode() {
    n=$1
    [ -e "$n" ] || return 0
    stat -c '%a' "$n" 2>/dev/null || stat -f '%Lp' "$n" 2>/dev/null || true
}

mod_mic_harden() {
    require_root
    ensure_dirs

    OYG_TMPDIR=${OYG_TMPDIR:-/tmp}
    rm -f "$OYG_TMPDIR/mic.devs" "$OYG_TMPDIR/mic.proc" 2>/dev/null || true

    nodes=$(mod_mic_list_capture_nodes)
    if [ -z "$nodes" ]; then
        warn "mic: no capture PCM nodes found (dynamic enumeration empty AND fallback empty)"
        print_status N/A "mic: no capture PCM nodes present on this system"
        return 0
    fi

    bound_count=0
    rc=0
    for n in $nodes; do
        # Reject anything that is NOT a capture node (ends in 'c'). The
        # dynamic enumeration already enforces this, but defense-in-depth:
        # the brief is explicit that playback nodes must never be touched.
        case "$n" in
            /dev/snd/pcmC[0-9]*D[0-9]*c) ;;
            *)
                err "mic: refusing to touch non-capture node $n"
                rc=1
                continue
                ;;
        esac

        base=$(basename "$n")

        if [ ! -e "$n" ]; then
            # In dry-run on a dev box without /dev/snd, the fallback list
            # is still enumerated. Print the planned actions so the
            # operator can see exactly what would happen on the device.
            # In a real run, treat a missing node as a soft skip — the
            # device may legitimately not have every node enumerated by
            # /proc/asound/pcm at this instant.
            if [ "$OYG_DRY_RUN" = "1" ]; then
                printf 'DRY-RUN: chmod 000 %s\n' "$n"
                printf 'DRY-RUN: mount --bind /dev/null %s\n' "$n"
                printf '[dry-run] mic: %s not present here; planned: chmod 000 + mount --bind /dev/null\n' "$n"
            else
                warn "mic: $n missing — skipping (node absent on this system)"
            fi
            continue
        fi

        # Record the original mode once. If we already recorded one for
        # this node in a previous harden run, reuse it so restore is exact.
        orig=$(state_get "mic.node.${base}.mode.orig")
        if [ -z "$orig" ]; then
            orig=$(mod_mic_node_mode "$n")
            [ -z "$orig" ] && orig="660"
            state_put "mic.node.${base}.mode.orig" "$orig"
        fi

        already=$(mod_mic_is_bound "$n")
        if [ "$already" = "1" ]; then
            ok "mic: $n already bind-mounted to /dev/null (idempotent)"
            state_put "mic.node.${base}.bound" "1"
            bound_count=$((bound_count + 1))
            continue
        fi

        # chmod 000 first — a process holding an open fd cannot bypass
        # the bind-mount, but stripping world+group perms is a cheap,
        # independent belt-and-braces on top of the bind.
        if run chmod 000 "$n" 2>/dev/null; then
            ok "mic: chmod 000 $n (was $orig)"
        else
            warn "mic: chmod 000 on $n denied (will still bind-mount)"
        fi

        if run mount --bind /dev/null "$n" 2>/dev/null; then
            ok "mic: mount --bind /dev/null $n (capture neutralised)"
            state_put "mic.node.${base}.bound" "1"
            bound_count=$((bound_count + 1))
        else
            err "mic: mount --bind /dev/null $n failed"
            state_drop "mic.node.${base}.bound"
            rc=1
        fi
    done

    if [ "$bound_count" -gt 0 ]; then
        state_put "mic.applied" "1"
    fi

    # Cleanup tmp
    rm -f "$OYG_TMPDIR/mic.devs" "$OYG_TMPDIR/mic.proc" 2>/dev/null || true

    return $rc
}

mod_mic_restore() {
    require_root

    nodes=$(mod_mic_list_capture_nodes)
    [ -z "$nodes" ] && nodes=$(state_get "mic.last_nodes")
    rc=0

    for n in $nodes; do
        base=$(basename "$n")
        bound=$(state_get "mic.node.${base}.bound")
        orig=$(state_get "mic.node.${base}.mode.orig")

        if [ "$bound" = "1" ]; then
            # Verify it is OURS — i.e. we recorded binding it. The
            # /proc/self/mounts check is belt-and-braces; we never
            # umount something we didn't mount.
            if mod_mic_is_bound "$n" | grep -q '^1$'; then
                if run umount "$n" 2>/dev/null; then
                    ok "mic: umounted $n"
                else
                    warn "mic: could not umount $n — manual cleanup required"
                    rc=1
                fi
            else
                warn "mic: $n was recorded as bound but is no longer mounted — leaving alone"
            fi
            state_drop "mic.node.${base}.bound"
        fi

        if [ -n "$orig" ] && [ "$orig" != "0" ] && [ -e "$n" ]; then
            if run chmod "$orig" "$n" 2>/dev/null; then
                ok "mic: $n mode restored to $orig"
            else
                warn "mic: could not restore mode on $n to $orig"
                rc=1
            fi
        fi
        state_drop "mic.node.${base}.mode.orig"
    done

    # Also tolerate old amixer state keys from previous installs. The old
    # mic.sh stored keys like mic.Capture.prev / mic.numid628.prev. We
    # do not re-run amixer (it's pointless on this device), but we drop
    # the stale keys so the state file stays clean and status doesn't
    # echo PARTIAL off them.
    for k in mic.applied \
             mic.Capture.prev mic.Capture.noperm \
             mic.Mic.prev mic.Mic.noperm \
             mic.numid628.prev mic.numid628.noperm; do
        state_drop "$k"
    done

    state_drop "mic.applied"
    return $rc
}

# Status helper: for one node, decide OK / FAIL / N/A.
# Prints nothing; sets the variables `mic_node_state` and `mic_node_detail`.
mod_mic_check_one() {
    n=$1
    alsa=$(mod_mic_node_to_alsa "$n")
    base=$(basename "$n")

    if [ "$OYG_DRY_RUN" = "1" ]; then
        bound=$(state_get "mic.node.${base}.bound")
        if [ "$bound" = "1" ]; then
            mic_node_state=OK
            mic_node_detail="mic: $n bind-mounted to /dev/null (dry-run)"
        else
            mic_node_state=N/A
            mic_node_detail="mic: $n not bound (dry-run)"
        fi
        return
    fi

    # Real check: bound-to-/dev/null right now?
    if mod_mic_is_bound "$n" | grep -q '^1$'; then
        # Active verification: try arecord. If arecord is missing, skip
        # the active test but still mark OK (the bind itself is the
        # guarantee).
        if have arecord && [ -n "$alsa" ]; then
            out=$(arecord -D "$alsa" -f S16_LE -r 16000 -c 1 -d 1 -t raw 2>/dev/null)
            rc_a=$?
            bytes=$(printf '%s' "$out" | wc -c | tr -d ' ')
            if [ "$bytes" = "0" ] || [ "$rc_a" != "0" ]; then
                mic_node_state=OK
                mic_node_detail="mic: $alsa ($n) bound, arecord produced 0 bytes / rc=$rc_a"
            else
                mic_node_state=FAIL
                mic_node_detail="mic: $alsa ($n) bound BUT arecord produced $bytes bytes — re-apply required"
            fi
        else
            if have arecord; then
                mic_node_state=OK
                mic_node_detail="mic: $n bind-mounted to /dev/null (no ALSA device string derivable)"
            else
                mic_node_state=OK
                mic_node_detail="mic: $n bind-mounted to /dev/null (arecord missing — active check skipped)"
            fi
        fi
        return
    fi

    mic_node_state=FAIL
    mic_node_detail="mic: $n NOT bound to /dev/null — capture still live"
}

mod_mic_status() {
    applied=$(state_get "mic.applied")
    [ "$applied" = "1" ] || {
        print_status N/A "mic: not hardened"
        return
    }

    nodes=$(mod_mic_list_capture_nodes)
    if [ -z "$nodes" ]; then
        print_status N/A "mic: no capture PCM nodes present on this system"
        return
    fi

    any_fail=0
    any_ok=0
    arecord_warn=0
    for n in $nodes; do
        mod_mic_check_one "$n"
        print_status "$mic_node_state" "$mic_node_detail"
        case "$mic_node_state" in
            OK)   any_ok=1 ;;
            FAIL) any_fail=1 ;;
        esac
    done

    # Operator-visible warning when arecord is missing — the check
    # above falls back to "bind present implies OK", which is honest
    # but weaker than the active test.
    if ! have arecord; then
        warn "mic: arecord not installed — active verification skipped; status reflects bind-mount state only"
    fi

    [ "$any_fail" = "1" ] && return 1
    return 0
}
