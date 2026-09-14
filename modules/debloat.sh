OYG_MOD_DEBLOAT=1

# debloat.sh — opt-in reclamation of RAM + attack surface by stopping
# unused feature services and neutralising one preloaded app.
#
# Why this is its own module (and not "more entries in services.sh")
# -----------------------------------------------------------------
# The brief calls for TWO enforcement classes mixed together:
#
#   1. systemd-managed units — same shape as services.sh:
#        <id>|<unit>|<process>
#      Treat as class-1 (systemctl stop really kills the process)
#      OR class-2 (luna-launched; stop is a no-op, kill is required),
#      per the verified device facts in FINDINGS.md (F33a).
#
#   2. luna-launched BINARIES — no systemd unit, sometimes a permanent
#      preload. Examples on this device:
#        /usr/bin/com.webos.app.voice       (preloaded app, ~51 MB)
#        /usr/sbin/lg.thinqai.adapter
#        /usr/sbin/airessrvallocator
#        /usr/sbin/com.webos.service.iotproxy
#        /usr/sbin/sportsalert
#      Neutralised the same way the `voice` module neutralises
#      /usr/sbin/voiceinput{,_hidraw},conductor:
#        chmod 000 <binary>          (best-effort; /usr is read-only)
#        mount --bind /dev/null      (the proven technique — works on
#          <binary>                    read-only /usr)
#        kill -TERM/-KILL the process named by basename(<binary>)
#
# Why we cannot use systemctl mask
# ---------------------------------
# Same reason as services.sh: /etc is read-only on this device, so
# `systemctl mask <unit>` ALWAYS fails with
#   Failed to mask unit: File /etc/systemd/system/<x>.service already
#   exists.
# The enforcement model is therefore "stop now + stop again on every
# boot", exactly as services.sh does. Persisted under $OYG_ROOT:
#   debloat.units.stopped   — unit names to stop at every boot
#   debloat.procs.kill      — process names to kill at every boot
# Both are re-applied by the init.d boot hook when state contains
# debloat.applied=1.
#
# Opt-in
# ------
# OYG_DEBLOAT=1   — required. Without it, harden() refuses and explains.
# This module BREAKS features by design: family-care, buddy-connector,
# alwaysready, AI inference, avahi/mDNS, the webOS rule engine, and the
# voice-app UI. All of those features have backends that are already
# blocked by the `network` module (ThinQ cloud), the `voice` module
# (Magic Remote mic pipeline), or the `policy` module (LG consents
# declined) — so disabling the front-ends is the natural completion of
# the chain and reclaims the RAM + attack surface they would have used.
#
# Reversibility
# -------------
# restore(): systemctl start any unit that was previously active,
# umount + chmod restore for any binary we bound, clear the boot-enforce
# lists. Never restart a process that was merely killed (they are
# luna-launched / preloaded and will respawn on demand if requested by
# the system).
#
# Verified device facts (per the brief):
#   Baseline MemAvailable ~434 MB, SwapFree ~186 MB, ~361 processes.
#   com.webos.app.voice is NOT a systemd unit; launched by app manager.
#   com.webos.service.familycare runs under iotjs, so pidof familycare
#   does not match — rely on systemctl stop only.
#   com.webos.app.voice: ~51 MB preload; binary is /usr/bin/com.webos.app.voice.

# --- spec: systemd units -----------------------------------------------------
# Format: <id>|<unit>|<process>
#
# Stop unit, kill the matching process if it is running. Same shape as
# services.sh. Process column may be empty ONLY when the unit is known
# not to have a matching pidof-able process name (e.g. familycare,
# which runs under iotjs and never matches `pidof familycare`).
#
# Tier C (operator-requested):
#   wowplay   LG wireless-display / screen-mirroring receiver.
#             Disabling it removes the "mirror your screen to the TV"
#             feature; UPnP/DLNA (upnpd, dmost, dmr, umediaserver) is
#             deliberately left RUNNING on this device. wowplay is
#             Type=static, so systemctl stop + kill is permanent and
#             ls-hubd does not respawn it.
#
#   uploadd   log-upload daemon (/usr/sbin/uploadd -v). This is the
#             component that ships device logs off-box — i.e. telemetry.
#             Disabling it stops log upload; local logging is unaffected.
#             uploadd's luna-service2 unit is Type=dynamic, which means
#             ls-hubd will re-exec it on the next LS2 call to
#             com.palm.uploadd — so `systemctl stop` + `kill` only
#             works until the next caller. The structural fix is to
#             bind-mount /dev/null over the binary itself, listed in
#             DEBLOAT_BINARIES_SPEC below. The unit entry is removed
#             from this spec to avoid misleading status reports; the
#             boot hook re-establishes the bind every boot.
DEBLOAT_UNITS_SPEC='
mycar|com.webos.service.mycar.service|com.webos.service.mycar
familycare|com.webos.service.familycare.service|
buddyconnector|com.webos.service.buddyconnector.service|com.webos.service.buddyconnector
alwaysready|alwaysready.service|alwaysready
ai-inference-manager|ai-inference-manager.service|ai-inference-manager
avahi-daemon|avahi-daemon.service|avahi-daemon
avahi-adaptor|avahi-adaptor.service|avahi-adaptor
ruleengine|com.webos.service.ruleengine.service|com.webos.service.ruleengine
wowplay|wowplay.service|wowplay
'

# --- spec: luna-launched binaries -------------------------------------------
# Absolute paths only. Verified at runtime: if the binary is absent on
# this build of webOS we skip gracefully and say so.
#
# The `<path>|<proc>` form sets the kill-name override; the bind target
# is always <path>. The `uploadd` entry is the structural fix for
# com.palm.uploadd: its LS2 service is Type=dynamic, so ls-hubd respawns
# it on the next call to luna://com.palm.uploadd and `systemctl stop`
# + `kill` is unwinnable — only `mount --bind /dev/null` over the
# binary itself stops the respawn (the exec'd process opens /dev/null
# and exits). wowplay is Type=static and is therefore handled in
# DEBLOAT_UNITS_SPEC; it does NOT appear here.
DEBLOAT_BINARIES_SPEC='
/usr/bin/com.webos.app.voice
/usr/sbin/lg.thinqai.adapter
/usr/sbin/airessrvallocator
/usr/sbin/com.webos.service.iotproxy
/usr/sbin/sportsalert
/usr/palm/services/com.webos.service.dial/discovery-server.js|ss.gateway
/usr/sbin/iconnectivity
/usr/sbin/sdx
/usr/sbin/uploadd|uploadd
'

# Per-entry "what feature is lost" — Tier B (boot-enforced):
#   /usr/palm/services/com.webos.service.dial/discovery-server.js|ss.gateway
#     DIAL second-screen / casting discovery server (TCP 8008). Runs
#     as /usr/bin/node with argv[0] literally "ss.gateway" so
#     `pidof ss.gateway` matches the running process (NOT the basename
#     of the script). The "|ss.gateway" suffix on the spec line
#     overrides the kill-by-basename default with the real process
#     name. Was burning CPU continuously (6m09s and climbing) with no
#     user request. Kills Chromecast / DIAL "cast to TV" discovery;
#     the launcher home screen still works.
#   /usr/sbin/iconnectivity
#     Phone-connectivity helper (LG TV Companion / mobile pairing).
#     Kills the "pair your phone" code path; casting via the ThinQ
#     app also relies on it.
#   /usr/sbin/sdx
#     Software-delivery daemon (over-the-air content / store-tile
#     delivery). Kills LG's content-update channel; the device still
#     launches installed apps but stops receiving new / updated
#     content tiles.
#   /usr/sbin/uploadd|uploadd
#     Log-upload daemon (sends device logs to LG — telemetry). The
#     `<path>|uploadd` form uses an explicit kill-name override only
#     because basename(uploadd) happens to equal uploadd (kept
#     explicit for symmetry with ss.gateway). The LS2 service
#     com.palm.uploadd is `Type=dynamic`, so ls-hubd respawns the
#     binary on the next luna-send to it — the only structural fix is
#     the bind-mount itself. The bind survives the process; even when
#     ls-hubd re-execs the path, the new process opens /dev/null and
#     exits immediately (verified: pidof uploadd is empty after the
#     bind, and a deliberate luna-send to com.palm.uploadd returns
#     `com.palm.uploadd is not running` with the PID still empty).

DEBLOAT_UNITS_STOPPED_LIST="$OYG_ROOT/debloat.units.stopped"
DEBLOAT_PROCS_KILL_LIST="$OYG_ROOT/debloat.procs.kill"

# Per-binary state keys:
#   debloat.bin.<path>.prev   — original mode (octal string)
#   debloat.bin.<path>.bound  — "1" if we bind-mounted /dev/null over it
# debloat.applied                      — "1" once harden completed

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------

# _mod_debloat_warn_enabled
#   Exit 0 iff the OYG_DEBLOAT=1 opt-in flag is set. Otherwise print
#   a refusal message and exit 1. The same shape as the network
#   module's opt-in gate (mod_network_harden refuses when
#   OYG_NETWORK_BLOCK!=1).
_mod_debloat_warn_enabled() {
    if [ "${OYG_DEBLOAT:-0}" = "1" ]; then
        return 0
    fi
    warn "debloat: OYG_DEBLOAT!=1 — refusing to disable feature services by default"
    warn "debloat: set OYG_DEBLOAT=1 oyg harden --only debloat to enable"
    warn "debloat: this disables: family / buddy / alwaysready / AI inference / avahi / ruleengine / voice UI"
    warn "debloat: restore with: oyg restore --only debloat"
    return 1
}

# _mod_debloat_load_units_spec
#   Print the units spec as one spec per line, comments and blanks
#   skipped. Same awk pipeline as services.sh.
_mod_debloat_load_units_spec() {
    printf '%s\n' "$DEBLOAT_UNITS_SPEC" | awk '
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        { sub(/[[:space:]]+$/, ""); print }
    '
}

# _mod_debloat_load_binaries_spec
#   Print the binaries spec as one absolute path per line, comments
#   and blanks skipped. Spec format per line:
#       <absolute-path>
#     OR (kill-name override):
#       <absolute-path>|<kill-name>
#   The second form is used when the process basename does NOT match
#   the basename of the file (e.g. node running a script with
#   argv[0] set to the real service name). The override only affects
#   the kill step; the bind target is always <absolute-path>.
_mod_debloat_load_binaries_spec() {
    printf '%s\n' "$DEBLOAT_BINARIES_SPEC" | awk '
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        { sub(/[[:space:]]+$/, ""); print }
    '
}

# _mod_debloat_split_spec <line>
#   Print "<path> <proc>" (two space-separated fields) from one spec
#   line. If no override is given, <proc> is basename(<path>).
_mod_debloat_split_spec() {
    line=$1
    [ -z "$line" ] && return 0
    case "$line" in
        \#*) return 0 ;;
    esac
    p=$(printf '%s' "$line" | awk -F'|' '{print $1}')
    override=$(printf '%s' "$line" | awk -F'|' '{
        if (NF >= 2 && $2 != "") print $2; else print ""
    }')
    if [ -z "$override" ]; then
        override=$(basename -- "$p" 2>/dev/null)
    fi
    printf '%s %s\n' "$p" "$override"
}

# _mod_debloat_unit_present <unit>
#   Print "1" if the unit is known to this systemd, "0" otherwise.
#   In dry-run, simulate "present" so the operator sees the full plan.
_mod_debloat_unit_present() {
    unit=$1
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf '1\n'
        return 0
    fi
    if systemctl list-unit-files 2>/dev/null \
        | awk '{print $1}' | grep -Fxq -- "$unit"; then
        printf '1\n'
        return 0
    fi
    printf '0\n'
    return 0
}

# _mod_debloat_query <unit> <what>
#   Print one cleaned line for `is-active` or `is-enabled`. Falls back
#   to "unknown" on systemctl failure. In dry-run, simulate inactive
#   + disabled (the operator wants to see the planned actions, not a
#   fake "already active" that would skip the stop).
_mod_debloat_query() {
    unit=$1
    what=$2
    if [ "$OYG_DRY_RUN" = "1" ]; then
        case "$what" in
            is-active)  printf 'inactive\n' ;;
            is-enabled) printf 'disabled\n' ;;
            *)          printf 'unknown\n' ;;
        esac
        return 0
    fi
    out=$(systemctl "$what" "$unit" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$out" ]; then
        printf 'unknown\n'
    else
        printf '%s\n' "$out"
    fi
}

# _mod_debloat_pids_for <process>
#   Print PIDs of <process> (basename match), one per line. Empty if
#   none. Prefers pidof, falls back to pgrep -x. Returns empty for an
#   empty <process> (familycare has no matching basename; per the brief
#   we treat a missing process as normal).
_mod_debloat_pids_for() {
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

# _mod_debloat_stop_unit <unit>
#   systemctl stop <unit>. In dry-run, echo the planned command.
_mod_debloat_stop_unit() {
    unit=$1
    [ -z "$unit" ] && return 0
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: systemctl stop %s\n' "$unit"
        return 0
    fi
    systemctl stop "$unit" 2>/dev/null
}

# _mod_debloat_kill_process <process>
#   TERM, sleep, KILL. Echoes one "pid <n> <signal>" line per actual
#   signal. Returns 0 if process is gone, 1 otherwise. In dry-run,
#   simulates the kill succeeding (mirrors services.sh).
_mod_debloat_kill_process() {
    proc=$1
    [ -z "$proc" ] && return 0
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'pid 99999 TERM\n'
        printf 'pid 99999 KILL\n'
        return 0
    fi
    pids=$(_mod_debloat_pids_for "$proc" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [ -z "$pids" ] && return 0
    for p in $pids; do
        if kill -TERM "$p" 2>/dev/null; then
            printf 'pid %s TERM\n' "$p"
        fi
    done
    sleep 1
    survivors=$(_mod_debloat_pids_for "$proc" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    for p in $survivors; do
        if kill -KILL "$p" 2>/dev/null; then
            printf 'pid %s KILL\n' "$p"
        fi
    done
    sleep 1
    [ -z "$(_mod_debloat_pids_for "$proc")" ] && return 0
    return 1
}

# _mod_debloat_record_unit <unit>
#   Append <unit> to debloat.units.stopped (idempotent). In dry-run,
#   echo the planned write.
_mod_debloat_record_unit() {
    unit=$1
    [ -z "$unit" ] && return 0
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: echo %s >> %s\n' "$unit" "$DEBLOAT_UNITS_STOPPED_LIST"
        return 0
    fi
    ensure_dirs
    touch "$DEBLOAT_UNITS_STOPPED_LIST" 2>/dev/null || return 1
    if ! grep -Fxq -- "$unit" "$DEBLOAT_UNITS_STOPPED_LIST" 2>/dev/null; then
        printf '%s\n' "$unit" >>"$DEBLOAT_UNITS_STOPPED_LIST" 2>/dev/null \
            || return 1
    fi
    return 0
}

# _mod_debloat_drop_unit <unit>
#   Remove <unit> from debloat.units.stopped.
_mod_debloat_drop_unit() {
    unit=$1
    [ -z "$unit" ] && return 0
    [ -r "$DEBLOAT_UNITS_STOPPED_LIST" ] || return 0
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: drop %s from %s\n' "$unit" "$DEBLOAT_UNITS_STOPPED_LIST"
        return 0
    fi
    tmp=$(mktemp 2>/dev/null) || return 1
    grep -Fvx -- "$unit" "$DEBLOAT_UNITS_STOPPED_LIST" >"$tmp" 2>/dev/null \
        && mv "$tmp" "$DEBLOAT_UNITS_STOPPED_LIST"
    rm -f "$tmp" 2>/dev/null
    return 0
}

# _mod_debloat_record_proc <proc>
#   Append <proc> to debloat.procs.kill (idempotent). Empty <proc>
#   is a no-op (e.g. familycare, where pidof would never match).
_mod_debloat_record_proc() {
    proc=$1
    [ -z "$proc" ] && return 0
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: echo %s >> %s\n' "$proc" "$DEBLOAT_PROCS_KILL_LIST"
        return 0
    fi
    ensure_dirs
    touch "$DEBLOAT_PROCS_KILL_LIST" 2>/dev/null || return 1
    if ! grep -Fxq -- "$proc" "$DEBLOAT_PROCS_KILL_LIST" 2>/dev/null; then
        printf '%s\n' "$proc" >>"$DEBLOAT_PROCS_KILL_LIST" 2>/dev/null \
            || return 1
    fi
    return 0
}

# _mod_debloat_drop_proc <proc>
#   Remove <proc> from debloat.procs.kill. Empty <proc> is a no-op.
_mod_debloat_drop_proc() {
    proc=$1
    [ -z "$proc" ] && return 0
    [ -r "$DEBLOAT_PROCS_KILL_LIST" ] || return 0
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: drop %s from %s\n' "$proc" "$DEBLOAT_PROCS_KILL_LIST"
        return 0
    fi
    tmp=$(mktemp 2>/dev/null) || return 1
    grep -Fvx -- "$proc" "$DEBLOAT_PROCS_KILL_LIST" >"$tmp" 2>/dev/null \
        && mv "$tmp" "$DEBLOAT_PROCS_KILL_LIST"
    rm -f "$tmp" 2>/dev/null
    return 0
}

# _mod_debloat_is_bound <path>
#   Echo "1" if <path> is currently a mount point per /proc/self/mounts
#   or /proc/self/mountinfo. Same pattern as voice.sh — we ASK
#   "is this a mount point?" and do NOT grep for the literal "/dev/null"
#   (a bind of /dev/null is recorded as root="/null", mountpoint=<path>,
#   fstype=devtmpfs on this device).
_mod_debloat_is_bound() {
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

# _mod_debloat_path_mode <path>
#   Echo the current mode of <path> as an octal string ("755"), or
#   empty if stat fails or the path is absent. Same fallback chain as
#   voice.sh.
_mod_debloat_path_mode() {
    p=$1
    [ -e "$p" ] || { printf ''; return 0; }
    stat -c '%a' "$p" 2>/dev/null || stat -f '%Lp' "$p" 2>/dev/null || true
}

# _mod_debloat_harden_one_bin <path>
#   Bind-neutralise <path>: record original mode, chmod 000, then
#   mount --bind /dev/null over it. Writes per-step diagnostics to
#   STDERR and a single status word "OK"/"FAIL"/"N/A" to STDOUT.
#   Caller captures only stdout with command substitution.
#   See voice.sh for why the stderr/stdout split matters.
_mod_debloat_harden_one_bin() {
    path=$1
    if [ -z "$path" ]; then
        printf 'N/A\n'
        return 0
    fi

    if [ ! -e "$path" ]; then
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: chmod 000 %s\n' "$path" >&2
            printf 'DRY-RUN: mount --bind /dev/null %s\n' "$path" >&2
            printf '[dry-run] debloat: %s not present here; planned: chmod 000 + mount --bind /dev/null\n' "$path" >&2
        else
            warn "debloat: $path absent — skipping (not present on this system)" >&2
        fi
        printf 'N/A\n'
        return 0
    fi

    orig=$(state_get "debloat.bin.${path}.prev")
    if [ -z "$orig" ]; then
        orig=$(_mod_debloat_path_mode "$path")
        [ -z "$orig" ] && orig="755"
        state_put "debloat.bin.${path}.prev" "$orig"
    fi

    if [ "$(_mod_debloat_is_bound "$path")" = "1" ]; then
        ok "debloat: $path already bind-mounted to /dev/null (idempotent)" >&2
        state_put "debloat.bin.${path}.bound" "1"
        printf 'OK\n'
        return 0
    fi

    if run chmod 000 "$path" 2>/dev/null; then
        ok "debloat: chmod 000 $path (was $orig)" >&2
    else
        warn "debloat: chmod 000 on $path denied (will still bind-mount)" >&2
    fi

    if run mount --bind /dev/null "$path" 2>/dev/null; then
        ok "debloat: mount --bind /dev/null $path (neutralised)" >&2
        state_put "debloat.bin.${path}.bound" "1"
        printf 'OK\n'
        return 0
    fi

    err "debloat: mount --bind /dev/null $path failed" >&2
    state_drop "debloat.bin.${path}.bound"
    printf 'FAIL\n'
    return 1
}

# _mod_debloat_join_pids <multiline>
#   Join newline-separated pids into a single space-separated line.
_mod_debloat_join_pids() {
    printf '%s' "$1" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# -----------------------------------------------------------------------------
# entry points
# -----------------------------------------------------------------------------

mod_debloat_harden() {
    _mod_debloat_warn_enabled || return 1
    require_root
    ensure_dirs

    have systemctl || [ "$OYG_DRY_RUN" = "1" ] \
        || { err "debloat: systemctl not found"; return 1; }
    if ! have systemctl && [ "$OYG_DRY_RUN" = "1" ]; then
        warn "debloat: systemctl not found — dry-run will simulate unit states (inactive)"
    fi

    warn "debloat: this disables features (family / buddy / AI / avahi / ruleengine / voice UI). Restore with: oyg restore --only debloat"
    warn "debloat: enforcement is 'stop unit + kill process + bind-neutralise preloaded binaries + re-apply on every boot' (systemctl mask is impossible on this device: read-only /etc)"

    rc=0

    # --- pass 1: systemd units ---
    for spec in $(_mod_debloat_load_units_spec); do
        id=$(printf '%s' "$spec"   | awk -F'|' '{print $1}')
        unit=$(printf '%s' "$spec" | awk -F'|' '{print $2}')
        proc=$(printf '%s' "$spec" | awk -F'|' '{print $3}')
        [ -z "$id" ] && continue
        [ -z "$unit" ] && unit=$id

        present=$(_mod_debloat_unit_present "$unit")
        is_active=$(_mod_debloat_query "$unit" is-active)
        is_enabled=$(_mod_debloat_query "$unit" is-enabled)
        prev_unit_state="${is_active}/${is_enabled}"
        if [ -n "$proc" ]; then
            prev_proc_state=$([ -n "$(_mod_debloat_pids_for "$proc")" ] \
                && printf 'running' || printf 'stopped')
        else
            # familycare-style: pidof never matches the real process
            # (it runs under iotjs). Record 'unknown' so restore does
            # not try to start something that was never running as a
            # basename-named process.
            prev_proc_state='unknown'
        fi
        state_put "debloat.unit.${id}.prev" "${prev_unit_state}|proc=${prev_proc_state}"

        unit_stopped=0
        unit_note=""
        if [ "$present" = "1" ]; then
            if [ "$is_active" = "active" ] || [ "$OYG_DRY_RUN" = "1" ]; then
                if _mod_debloat_stop_unit "$unit"; then
                    if [ "$is_active" = "active" ]; then
                        unit_stopped=1
                    fi
                else
                    err "debloat: $id stop <$unit> FAILED"
                    rc=1
                fi
            else
                unit_note="unit was already $is_active"
            fi
        else
            unit_note="unit absent"
        fi

        proc_pids_before=""
        proc_killed=0
        proc_note=""
        if [ -n "$proc" ]; then
            proc_pids_before=$(_mod_debloat_pids_for "$proc")
            if [ -n "$proc_pids_before" ]; then
                kill_log=$(_mod_debloat_kill_process "$proc")
                if [ -n "$kill_log" ]; then
                    saved_ifs=$IFS
                    IFS='
'
                    for line in $kill_log; do
                        [ -n "$line" ] && ok "debloat: $id — $line"
                    done
                    IFS=$saved_ifs
                fi
                remaining=$(_mod_debloat_pids_for "$proc")
                if [ -n "$remaining" ]; then
                    err "debloat: $id process <$proc> still running after TERM+KILL (pids: $(_mod_debloat_join_pids "$remaining"))"
                    rc=1
                    proc_note="process survived"
                else
                    proc_killed=1
                    proc_note="process killed"
                fi
            else
                proc_note="process was not running"
            fi
        else
            proc_note="process column empty (relies on systemctl stop; see brief)"
        fi

        _mod_debloat_record_unit "$unit" \
            && ok "debloat: $id added to boot-enforced stop list ($DEBLOAT_UNITS_STOPPED_LIST)" \
            || warn "debloat: could not record $unit in boot-enforced stop list"
        _mod_debloat_record_proc "$proc" \
            && ok "debloat: $id added to boot-enforced kill list ($DEBLOAT_PROCS_KILL_LIST)" \
            || warn "debloat: could not record $proc in boot-enforced kill list"

        joined_pids=$(_mod_debloat_join_pids "$proc_pids_before")
        if [ "$unit_stopped" = "1" ] && [ "$proc_killed" = "1" ]; then
            ok "debloat: $id — unit stopped + $proc_note (pid $joined_pids)"
        elif [ "$unit_stopped" = "1" ]; then
            ok "debloat: $id — unit stopped ($unit_note)"
        elif [ "$proc_killed" = "1" ]; then
            ok "debloat: $id — $proc_note (pid $joined_pids)"
        else
            ok "debloat: $id — already stopped ($unit_note, $proc_note)"
        fi
    done

    # --- pass 2: luna-launched binaries (no systemd unit) ---
    ok_count=0
    fail_count=0
    for spec_line in $(_mod_debloat_load_binaries_spec); do
        [ -z "$spec_line" ] && continue
        case "$spec_line" in
            ""|\#*) continue ;;
        esac
        split=$(_mod_debloat_split_spec "$spec_line")
        path=$(printf '%s' "$split" | awk '{print $1}')
        [ -z "$path" ] && continue
        status_line=$(_mod_debloat_harden_one_bin "$path")
        case "$status_line" in
            OK)   ok_count=$((ok_count + 1)) ;;
            FAIL) fail_count=$((fail_count + 1)); rc=1 ;;
        esac
    done

    # Termination pass for the binaries. Same shape as voice.sh:
    # kill the basename after the binds, so any process that tries to
    # re-exec the binary as it dies hits the bind immediately. Only
    # kill if the binary exists on this box — else we'd be hunting a
    # name that nothing uses. Use the per-spec kill-name override when
    # present (see _mod_debloat_split_spec) so e.g. node running a
    # script with argv[0]=ss.gateway still picks up the real PIDs.
    for spec_line in $(_mod_debloat_load_binaries_spec); do
        [ -z "$spec_line" ] && continue
        case "$spec_line" in
            ""|\#*) continue ;;
        esac
        split=$(_mod_debloat_split_spec "$spec_line")
        path=$(printf '%s' "$split" | awk '{print $1}')
        proc=$(printf '%s' "$split" | awk '{print $2}')
        [ -z "$path" ] && continue
        [ -z "$proc" ] && proc=$(basename -- "$path" 2>/dev/null)
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: kill %s (TERM then KILL if needed)\n' "$proc"
            continue
        fi
        [ -e "$path" ] || continue
        out=$(_mod_debloat_kill_process "$proc")
        if [ -n "$out" ]; then
            printf '%s\n' "$out" | while IFS= read -r line; do
                [ -n "$line" ] && ok "debloat: $proc $line"
            done
        fi
    done

    state_put "debloat.applied" "1"
    return $rc
}

mod_debloat_restore() {
    require_root

    rc=0

    # --- units ---
    for spec in $(_mod_debloat_load_units_spec); do
        id=$(printf '%s' "$spec"   | awk -F'|' '{print $1}')
        unit=$(printf '%s' "$spec" | awk -F'|' '{print $2}')
        proc=$(printf '%s' "$spec" | awk -F'|' '{print $3}')
        [ -z "$id" ] && continue
        [ -z "$unit" ] && unit=$id

        prev=$(state_get "debloat.unit.${id}.prev")
        was_active=$(printf '%s' "$prev" | awk -F'|' '{print $1}' | cut -d/ -f1)

        if [ "$was_active" = "active" ]; then
            if _mod_debloat_stop_unit "$unit" 2>/dev/null || true; then
                if [ "$(_mod_debloat_unit_present "$unit")" = "1" ]; then
                    if run systemctl start "$unit" 2>/dev/null; then
                        ok "debloat: $id unit <$unit> started (restored)"
                    else
                        warn "debloat: start $unit failed (will leave stopped)"
                        rc=1
                    fi
                fi
            fi
        else
            ok "debloat: $id left stopped (unit was not active originally: $was_active)"
        fi

        # Do NOT restart killed processes — they are luna-launched /
        # preloaded. The system respawns them on demand if requested.
        if [ -n "$proc" ]; then
            if [ -n "$(_mod_debloat_pids_for "$proc")" ]; then
                warn "debloat: $id process <$proc> is still running; not restarting (on-demand — will respawn if requested)"
            else
                ok "debloat: $id process <$proc> left stopped (on-demand — will respawn if requested)"
            fi
        else
            ok "debloat: $id has no process column; nothing to restart"
        fi

        _mod_debloat_drop_unit "$unit"
        _mod_debloat_drop_proc "$proc"
        state_drop "debloat.unit.${id}.prev"
    done

    # --- binaries ---
    for spec_line in $(_mod_debloat_load_binaries_spec); do
        [ -z "$spec_line" ] && continue
        case "$spec_line" in
            ""|\#*) continue ;;
        esac
        split=$(_mod_debloat_split_spec "$spec_line")
        path=$(printf '%s' "$split" | awk '{print $1}')
        [ -z "$path" ] && continue

        bound=$(state_get "debloat.bin.${path}.bound")
        orig=$(state_get "debloat.bin.${path}.prev")

        if [ "$bound" = "1" ]; then
            if [ "$(_mod_debloat_is_bound "$path")" = "1" ]; then
                if run umount "$path" 2>/dev/null; then
                    ok "debloat: umounted $path"
                else
                    warn "debloat: could not umount $path — manual cleanup required"
                    rc=1
                fi
            else
                warn "debloat: $path was recorded as bound but is no longer mounted — leaving alone"
            fi
            state_drop "debloat.bin.${path}.bound"
        fi

        if [ -n "$orig" ] && [ "$orig" != "0" ] && [ -e "$path" ]; then
            if run chmod "$orig" "$path" 2>/dev/null; then
                ok "debloat: $path mode restored to $orig"
            else
                warn "debloat: could not restore mode on $path to $orig"
                rc=1
            fi
        fi
        state_drop "debloat.bin.${path}.prev"
    done

    state_drop "debloat.applied"
    return $rc
}

mod_debloat_status() {
    disabled_count=0

    # --- units ---
    for spec in $(_mod_debloat_load_units_spec); do
        id=$(printf '%s' "$spec"   | awk -F'|' '{print $1}')
        unit=$(printf '%s' "$spec" | awk -F'|' '{print $2}')
        proc=$(printf '%s' "$spec" | awk -F'|' '{print $3}')
        [ -z "$id" ] && continue
        [ -z "$unit" ] && unit=$id

        present=$(_mod_debloat_unit_present "$unit")
        is_active=$(_mod_debloat_query "$unit" is-active)
        is_enabled=$(_mod_debloat_query "$unit" is-enabled)

        boot_stop=0
        if [ -r "$DEBLOAT_UNITS_STOPPED_LIST" ] \
            && grep -Fxq -- "$unit" "$DEBLOAT_UNITS_STOPPED_LIST" 2>/dev/null; then
            boot_stop=1
        fi
        boot_kill=0
        if [ -n "$proc" ] && [ -r "$DEBLOAT_PROCS_KILL_LIST" ] \
            && grep -Fxq -- "$proc" "$DEBLOAT_PROCS_KILL_LIST" 2>/dev/null; then
            boot_kill=1
        fi

        proc_running=0
        proc_running_pids=""
        if [ -n "$proc" ]; then
            proc_running_pids=$(_mod_debloat_pids_for "$proc")
            if [ -n "$proc_running_pids" ]; then
                proc_running=1
            fi
        fi

        unit_detail="unit=$is_active enabled=$is_enabled"
        proc_detail=""
        if [ -n "$proc" ]; then
            if [ "$proc_running" = "1" ]; then
                proc_detail=", process=running (pid $(_mod_debloat_join_pids "$proc_running_pids"))"
            else
                proc_detail=", process=stopped"
            fi
        else
            proc_detail=", process=n/a (pidof would not match on this device)"
        fi
        boot_detail="boot-enforced: stop=$boot_stop kill=$boot_kill"

        if [ "$proc_running" = "1" ]; then
            print_status FAIL "$id: $unit_detail$proc_detail — $boot_detail"
        elif [ "$present" != "1" ] && [ "$proc_running" = "0" ] && [ "$boot_stop" = "0" ] && [ "$boot_kill" = "0" ]; then
            print_status N/A "$id: unit absent + process not found ($unit, ${proc:-<none>})"
        elif [ "$is_active" = "active" ]; then
            print_status FAIL "$id: $unit_detail$proc_detail — $boot_detail"
        elif [ "$present" != "1" ]; then
            print_status N/A "$id: $unit absent ($unit)"
        else
            # unit inactive (or unknown) AND process not running
            disabled_count=$((disabled_count + 1))
            print_status OK "$id: $unit_detail$proc_detail — $boot_detail"
        fi
    done

    # --- binaries ---
    for spec_line in $(_mod_debloat_load_binaries_spec); do
        [ -z "$spec_line" ] && continue
        case "$spec_line" in
            ""|\#*) continue ;;
        esac
        split=$(_mod_debloat_split_spec "$spec_line")
        path=$(printf '%s' "$split" | awk '{print $1}')
        proc=$(printf '%s' "$split" | awk '{print $2}')
        [ -z "$path" ] && continue
        [ -z "$proc" ] && proc=$(basename -- "$path" 2>/dev/null)
        name=$proc

        if [ ! -e "$path" ]; then
            print_status N/A "$name ($path) absent on this system"
            continue
        fi

        if [ "$(_mod_debloat_is_bound "$path")" = "1" ]; then
            still=$(_mod_debloat_pids_for "$name")
            if [ -z "$still" ]; then
                disabled_count=$((disabled_count + 1))
                print_status OK "$name ($path) bound to /dev/null, process gone"
            else
                print_status FAIL "$name ($path) bound but process still running (pids: $still)"
            fi
        else
            print_status FAIL "$name ($path) NOT bound to /dev/null — preload live"
        fi
    done

    if [ "$disabled_count" -gt 0 ]; then
        ok "debloat: $disabled_count target(s) currently disabled"
    fi
}