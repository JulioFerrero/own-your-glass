OYG_MOD_SERVICES=1

# services.sh — stop a configurable list of background services.
# `systemctl mask` is impossible (/etc read-only overlay — F14a); the model
# is "stop unit + kill process + re-apply every boot" via $OYG_ROOT/
# services.stopped + services.kill. Two classes: systemd-managed (stop
# works) and luna-launched (unit is a dead one-shot — kill the PROCESS;
# unit-stop alone used to lie in status; F33a). Spec <id>|<unit>|<process>.
# Safe: contentminer (F20), objectdetection (F22), adoverlay, acr, remotediag;
# aggressive: iot-client, pushclient (F33). Details: docs/FINDINGS.md (F20, F22, F33a, F14a)

mod_services_safe_spec='
contentminer|contentminer.service|contentminer
objectdetection|objectdetection.service|objectdetection
adoverlay|adoverlay.service|adoverlay
acr|acr.service|acr
remotediag|remotediag.service|remotediag
'

mod_services_aggressive_spec='
iot-client|iot-client.service|iot-client
pushclient|com.webos.service.pushclient.service|com.webos.service.pushclient
'

STOPPED_LIST="$OYG_ROOT/services.stopped"
KILL_LIST="$OYG_ROOT/services.kill"
# _mod_services_dryrun_state is a transient file used only in dry-run
# mode to simulate "process gone after kill". Best-effort location:
# OYG_ROOT if writable, else $TMPDIR, else /tmp. Missing file == no
# simulated kills recorded, which is harmless.
if [ -d "$OYG_ROOT" ] && [ -w "$OYG_ROOT" ]; then
    _mod_services_dryrun_state="$OYG_ROOT/.dryrun-killed.$$"
elif [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then
    _mod_services_dryrun_state="$TMPDIR/.oyg-dryrun-killed.$$"
else
    _mod_services_dryrun_state="/tmp/.oyg-dryrun-killed.$$"
fi

# _mod_services_load_specs
#   Prints the combined spec list (safe + aggressive when enabled) as
#   one spec per line. Empty lines and comments are skipped.
_mod_services_load_specs() {
    printf '%s\n%s\n' "$mod_services_safe_spec" "$mod_services_aggressive_spec" \
        | awk '
            /^[[:space:]]*$/ { next }
            /^[[:space:]]*#/ { next }
            { sub(/[[:space:]]+$/, ""); print }
        '
}

# _mod_services_spec_for_id <id>
#   Prints the spec line for <id>, or empty string if not present.
_mod_services_spec_for_id() {
    want=$1
    _mod_services_load_specs | awk -F'|' -v w="$want" '$1 == w { print; exit }'
}

# _mod_services_active_specs
#   Print specs that should be enforced this run: safe always,
#   aggressive only when OYG_AGGRESSIVE=1.
_mod_services_active_specs() {
    if [ "${OYG_AGGRESSIVE:-0}" = "1" ]; then
        _mod_services_load_specs
    else
        printf '%s\n' "$mod_services_safe_spec" \
            | awk '
                /^[[:space:]]*$/ { next }
                /^[[:space:]]*#/ { next }
                { sub(/[[:space:]]+$/, ""); print }
            '
    fi
}

# _mod_services_record_stopped <unit>
#   Append a unit name to the persisted stop-list (one per line).
#   Idempotent: re-adding an existing entry is a no-op.
_mod_services_record_stopped() {
    unit=$1
    [ -z "$unit" ] && return 0
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: echo %s >> %s\n' "$unit" "$STOPPED_LIST"
        return 0
    fi
    ensure_dirs
    touch "$STOPPED_LIST" 2>/dev/null || return 1
    if ! grep -Fxq -- "$unit" "$STOPPED_LIST" 2>/dev/null; then
        printf '%s\n' "$unit" >>"$STOPPED_LIST" 2>/dev/null || return 1
    fi
    return 0
}

# _mod_services_drop_stopped <unit>
#   Remove a unit name from the persisted stop-list.
_mod_services_drop_stopped() {
    unit=$1
    [ -z "$unit" ] && return 0
    [ -r "$STOPPED_LIST" ] || return 0
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: drop %s from %s\n' "$unit" "$STOPPED_LIST"
        return 0
    fi
    tmp=$(mktemp 2>/dev/null) || return 1
    grep -Fvx -- "$unit" "$STOPPED_LIST" >"$tmp" 2>/dev/null \
        && mv "$tmp" "$STOPPED_LIST"
    rm -f "$tmp" 2>/dev/null
    return 0
}

# _mod_services_record_kill <process>
#   Append a process name to the persisted kill-list. Idempotent.
_mod_services_record_kill() {
    proc=$1
    [ -z "$proc" ] && return 0
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: echo %s >> %s\n' "$proc" "$KILL_LIST"
        return 0
    fi
    ensure_dirs
    touch "$KILL_LIST" 2>/dev/null || return 1
    if ! grep -Fxq -- "$proc" "$KILL_LIST" 2>/dev/null; then
        printf '%s\n' "$proc" >>"$KILL_LIST" 2>/dev/null || return 1
    fi
    return 0
}

# _mod_services_drop_kill <process>
#   Remove a process name from the persisted kill-list.
_mod_services_drop_kill() {
    proc=$1
    [ -z "$proc" ] && return 0
    [ -r "$KILL_LIST" ] || return 0
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: drop %s from %s\n' "$proc" "$KILL_LIST"
        return 0
    fi
    tmp=$(mktemp 2>/dev/null) || return 1
    grep -Fvx -- "$proc" "$KILL_LIST" >"$tmp" 2>/dev/null \
        && mv "$tmp" "$KILL_LIST"
    rm -f "$tmp" 2>/dev/null
    return 0
}

# _mod_services_unit_present <unit>
#   prints "1" if the unit is known to this systemd, "0" otherwise.
#   Accepts the full unit name (may include `.service`, `.timer`, etc.).
_mod_services_unit_present() {
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

# _mod_services_query <unit> <what>
#   Print one cleaned line for `is-active` or `is-enabled`. Strips
#   whitespace and collapses any multi-line response to a single token.
#   Falls back to "unknown" when systemctl exits non-zero.
_mod_services_query() {
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

# _mod_services_pids_for <process>
#   Print PIDs of <process> (basename match) one per line, or empty if
#   none. Prefers `pidof` (busybox / procps), falls back to `pgrep -x`.
#   In dry-run, simulates the process as "running" with a fake PID
#   until _mod_services_kill_process records it as killed in the
#   dry-run state file.
_mod_services_pids_for() {
    proc=$1
    [ -z "$proc" ] && return 0
    if [ "$OYG_DRY_RUN" = "1" ]; then
        if [ -r "$_mod_services_dryrun_state" ] \
            && grep -Fxq -- "$proc" "$_mod_services_dryrun_state" 2>/dev/null; then
            return 0
        fi
        printf '99999\n'
        return 0
    fi
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

# _mod_services_stop_unit <unit>
#   systemctl stop <unit>. Echoes nothing; returns 0 on success.
_mod_services_stop_unit() {
    unit=$1
    [ -z "$unit" ] && return 0
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: systemctl stop %s\n' "$unit"
        return 0
    fi
    systemctl stop "$unit" 2>/dev/null
}

# _mod_services_kill_process <process>
#   TERM, sleep, KILL if still alive. Prints one line per pid actually
#   signalled, in the form "pid <pid> <signal>" (caller captures with
#   command substitution). Returns 0 if the process is gone afterwards,
#   1 otherwise. In dry-run, simulates the kill succeeding without
#   actually signalling.
_mod_services_kill_process() {
    proc=$1
    [ -z "$proc" ] && return 0
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'pid 99999 TERM\n'
        printf 'pid 99999 KILL\n'
        printf '%s\n' "$proc" >>"$_mod_services_dryrun_state" 2>/dev/null || true
        return 0
    fi
    pids=$(_mod_services_pids_for "$proc" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [ -z "$pids" ] && return 0
    for p in $pids; do
        if kill -TERM "$p" 2>/dev/null; then
            printf 'pid %s TERM\n' "$p"
        fi
    done
    sleep 1
    survivors=$(_mod_services_pids_for "$proc" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    for p in $survivors; do
        if kill -KILL "$p" 2>/dev/null; then
            printf 'pid %s KILL\n' "$p"
        fi
    done
    sleep 1
    [ -z "$(_mod_services_pids_for "$proc")" ] && return 0
    return 1
}

# _mod_services_join_pids <multiline>
#   Join newline-separated pids into a single space-separated line and
#   trim trailing whitespace. Returns empty for empty input.
_mod_services_join_pids() {
    printf '%s' "$1" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

mod_services_harden() {
    require_root
    ensure_dirs
    rm -f "$_mod_services_dryrun_state" 2>/dev/null || true
    if [ "${OYG_AGGRESSIVE:-0}" = "1" ]; then
        warn "aggressive mode: also targeting iot-client + pushclient (may break ThinQ/voice/push)"
    else
        warn "aggressive mode OFF (set OYG_AGGRESSIVE=1 to also block: iot-client, pushclient)"
    fi

    have systemctl || [ "$OYG_DRY_RUN" = "1" ] \
        || { err "systemctl not found"; return 1; }
    if ! have systemctl && [ "$OYG_DRY_RUN" = "1" ]; then
        warn "systemctl not found — dry-run will simulate unit states (inactive)"
    fi
    warn "services: enforcement is 'stop unit + kill process + re-apply on every boot' (systemctl mask is impossible on this device: read-only /etc)"

    rc=0
    : >"$_mod_services_dryrun_state" 2>/dev/null || true
    for spec in $(_mod_services_active_specs); do
        id=$(printf '%s' "$spec"   | awk -F'|' '{print $1}')
        unit=$(printf '%s' "$spec" | awk -F'|' '{print $2}')
        proc=$(printf '%s' "$spec" | awk -F'|' '{print $3}')
        [ -z "$id" ] && continue
        [ -z "$unit" ] && unit=$id
        [ -z "$proc" ] && proc=$id

        present=$(_mod_services_unit_present "$unit")
        is_active=$(_mod_services_query "$unit" is-active)
        is_enabled=$(_mod_services_query "$unit" is-enabled)
        prev_unit_state="${is_active}/${is_enabled}"
        prev_proc_state=$([ -n "$(_mod_services_pids_for "$proc")" ] \
            && printf 'running' || printf 'stopped')
        state_put "services.${id}.prev" "${prev_unit_state}|proc=${prev_proc_state}"

        unit_stopped=0
        unit_note=""
        if [ "$present" = "1" ]; then
            if [ "$is_active" = "active" ] || [ "$OYG_DRY_RUN" = "1" ]; then
                if _mod_services_stop_unit "$unit"; then
                    if [ "$is_active" = "active" ]; then
                        unit_stopped=1
                    fi
                else
                    err "services: $id stop <$unit> FAILED"
                    rc=1
                fi
            else
                unit_note="unit was already $is_active"
            fi
        else
            unit_note="unit absent"
        fi

        proc_pids_before=$(_mod_services_pids_for "$proc")
        proc_killed=0
        proc_note=""
        if [ -n "$proc_pids_before" ]; then
            kill_log=$(_mod_services_kill_process "$proc")
            if [ -n "$kill_log" ]; then
                saved_ifs=$IFS
                IFS='
'
                for line in $kill_log; do
                    [ -n "$line" ] && ok "services: $id — $line"
                done
                IFS=$saved_ifs
            fi
            remaining=$(_mod_services_pids_for "$proc")
            if [ -n "$remaining" ]; then
                err "services: $id process <$proc> still running after TERM+KILL (pids: $(_mod_services_join_pids "$remaining"))"
                rc=1
                proc_note="process survived"
            else
                proc_killed=1
                proc_note="process killed"
            fi
        else
            proc_note="process was not running"
        fi

        _mod_services_record_stopped "$unit" \
            && ok "services: $id added to boot-enforced stop list ($STOPPED_LIST)" \
            || warn "services: could not record $unit in boot-enforced stop list"
        _mod_services_record_kill "$proc" \
            && ok "services: $id added to boot-enforced kill list ($KILL_LIST)" \
            || warn "services: could not record $proc in boot-enforced kill list"

        joined_pids=$(_mod_services_join_pids "$proc_pids_before")
        if [ "$unit_stopped" = "1" ] && [ "$proc_killed" = "1" ]; then
            ok "services: $id — unit stopped + $proc_note (pid $joined_pids)"
        elif [ "$unit_stopped" = "1" ]; then
            ok "services: $id — unit stopped ($unit_note)"
        elif [ "$proc_killed" = "1" ]; then
            ok "services: $id — $proc_note (pid $joined_pids)"
        else
            ok "services: $id — already stopped ($unit_note, $proc_note)"
        fi
    done
    state_put "services.applied" "1"
    [ "$rc" = "0" ] && return 0 || return 1
}

mod_services_restore() {
    require_root
    have systemctl || [ "$OYG_DRY_RUN" = "1" ] \
        || { err "systemctl not found"; return 1; }

    for spec in $(_mod_services_active_specs); do
        id=$(printf '%s' "$spec"   | awk -F'|' '{print $1}')
        unit=$(printf '%s' "$spec" | awk -F'|' '{print $2}')
        proc=$(printf '%s' "$spec" | awk -F'|' '{print $3}')
        [ -z "$id" ] && continue
        [ -z "$unit" ] && unit=$id
        [ -z "$proc" ] && proc=$id

        prev=$(state_get "services.${id}.prev")
        was_active=$(printf '%s' "$prev" | awk -F'|' '{print $1}' | cut -d/ -f1)

        if [ "$was_active" = "active" ]; then
            if _mod_services_stop_unit "$unit" 2>/dev/null || true; then
                if [ "$(_mod_services_unit_present "$unit")" = "1" ]; then
                    if run systemctl start "$unit" 2>/dev/null; then
                        ok "services: $id unit <$unit> started (restored)"
                    else
                        warn "services: start $unit failed (will leave stopped)"
                    fi
                fi
            fi
        else
            ok "services: $id left stopped (unit was not active originally: $was_active)"
        fi

        if [ -n "$(_mod_services_pids_for "$proc")" ]; then
            warn "services: $id process <$proc> is still running; not restarting (luna-launched / on-demand — will respawn if requested)"
        else
            ok "services: $id process <$proc> left stopped (on-demand service; will respawn if requested by the system)"
        fi

        _mod_services_drop_stopped "$unit"
        _mod_services_drop_kill "$proc"
        state_drop "services.${id}.prev"
    done
    state_drop "services.applied"
}

mod_services_status() {
    have systemctl || [ "$OYG_DRY_RUN" = "1" ] \
        || { print_status N/A "systemctl not available"; return; }
    applied=$(state_get "services.applied")

    for spec in $(_mod_services_active_specs); do
        id=$(printf '%s' "$spec"   | awk -F'|' '{print $1}')
        unit=$(printf '%s' "$spec" | awk -F'|' '{print $2}')
        proc=$(printf '%s' "$spec" | awk -F'|' '{print $3}')
        [ -z "$id" ] && continue
        [ -z "$unit" ] && unit=$id
        [ -z "$proc" ] && proc=$id

        present=$(_mod_services_unit_present "$unit")
        is_active=$(_mod_services_query "$unit" is-active)
        is_enabled=$(_mod_services_query "$unit" is-enabled)

        boot_stop=0
        if [ -r "$STOPPED_LIST" ] && grep -Fxq -- "$unit" "$STOPPED_LIST" 2>/dev/null; then
            boot_stop=1
        fi
        boot_kill=0
        if [ -r "$KILL_LIST" ] && grep -Fxq -- "$proc" "$KILL_LIST" 2>/dev/null; then
            boot_kill=1
        fi

        proc_running_pids=$(_mod_services_pids_for "$proc")
        proc_running=0
        if [ -n "$proc_running_pids" ]; then
            proc_running=1
        fi

        unit_detail="unit=$is_active enabled=$is_enabled"
        proc_detail="process=$proc"
        if [ "$proc_running" = "1" ]; then
            proc_detail="process=running (pid $(printf '%s' "$proc_running_pids" | tr '\n' ' ' | sed 's/[[:space:]]*$//'))"
        else
            proc_detail="process=stopped"
        fi
        boot_detail="boot-enforced: stop=$boot_stop kill=$boot_kill"

        if [ "$proc_running" = "1" ]; then
            print_status FAIL "$id: $proc_detail, $unit_detail — $boot_detail"
        elif [ "$present" != "1" ] && [ -z "$proc_running_pids" ] && [ "$boot_stop" = "0" ] && [ "$boot_kill" = "0" ]; then
            print_status N/A "$id: unit absent + process not found ($unit, $proc)"
        elif [ "$applied" = "1" ] && [ "$boot_stop" = "1" ] && [ "$boot_kill" = "1" ]; then
            print_status OK "$id: $unit_detail, $proc_detail — $boot_detail"
        elif [ "$applied" = "1" ]; then
            print_status PARTIAL "$id: $unit_detail, $proc_detail — $boot_detail (will resume after reboot)"
        elif [ "$present" != "1" ] && [ -z "$proc_running_pids" ]; then
            print_status N/A "$id: unit absent + process not found ($unit, $proc)"
        else
            print_status FAIL "$id: $unit_detail, $proc_detail — $boot_detail"
        fi
    done
}
