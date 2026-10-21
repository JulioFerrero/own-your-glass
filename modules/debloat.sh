OYG_MOD_DEBLOAT=1

# debloat.sh — RAM + attack-surface reclamation: stop unused feature
# units (same shape as services.sh) and bind-neutralise luna-launched
# preloaded binaries (chmod 000 + mount --bind /dev/null; /usr read-only).
# Part of a plain `oyg harden`. Disables features
# (family/buddy/alwaysready/AI/avahi/ruleengine/voice UI) whose backends
# are already blocked by network/voice/policy. mask impossible (/etc
# read-only) → "stop now + stop again every boot". Bugs A/B/C documented
# inline; never restart merely-killed processes. Details: docs/FINDINGS.md (F40, F40b, F40c, F42)

# --- spec: systemd units — format <id>|<unit>|<process> (same as services.sh).
# wowplay (Type=static): stop+kill is permanent. uploadd (Type=dynamic) is
# respawned by ls-hubd on the next LS2 call — handled in the binaries spec
# via bind-mount, not here (F40c).
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
cups-lpd|cups-lpd.socket|
dmost|dmost.service|dmost
ninfod|ninfod.service|ninfod
rdxd|rdxd.service|rdxd
service-logger|service-logger.service|service-logger
'
# Added after the 2026-10-21 audit (F48), none behind a user-visible feature:
#   cups-lpd.socket  LPD print server listening on the LAN (port 515)
#   dmost            LG Channels beacons (CDP session IDs, foreground app,
#                    last channel) sent through sdx
#   ninfod           answers IPv6 node-information queries (hostname,
#                    addresses) from any host
#   rdxd             builds crash and analytics reports for uploadd
#   service-logger   usage events: foreground app, first-use apps, HDMI
#                    devices, monthly input list

# --- spec: luna-launched binaries — absolute paths; absent paths are
# skipped gracefully at runtime. `<path>|<proc>` sets a kill-name override
# (the bind target is always <path>); uploadd needs `<path>|uploadd` because
# its LS2 service is Type=dynamic and only the bind stops the respawn (F40c).
DEBLOAT_BINARIES_SPEC='
/usr/bin/com.webos.app.voice
/usr/sbin/lg.thinqai.adapter
/usr/sbin/airessrvallocator
/usr/sbin/com.webos.service.iotproxy
/usr/sbin/sportsalarm
/usr/sbin/iconnectivity
/usr/sbin/uploadd|uploadd
/usr/sbin/amazon-alexa-adapter
/usr/sbin/performer
/usr/sbin/nlpmanager
/usr/palm/services/com.webos.service.familycare/index.js|cmd:com.webos.service.familycare
'

# With aggressive services (OYG_AGGRESSIVE=1, or iot-client already in the
# services module's boot kill list): iot-client is Type=dynamic, so ls-hubd
# respawns it after every kill; only the bind keeps it down (F48).
DEBLOAT_BINARIES_AGGRESSIVE_SPEC='
/usr/palm/services/com.webos.service.iotclient/iot-client
'

# --- spec: apps LG keeps loaded in the background — <appId>|<how>, where
# <how> is a comma list:
#   preload  switched off in LG's preload manager (webos-preload-manager),
#            which otherwise loads the app again after every close. The
#            switch lives in memory only, so every boot re-applies it.
#   close    closed while it sits in the background, never while it is on
#            screen. Through the web-app manager's killApp: SAM's
#            closeByAppId answers returnValue:true for amazon.alexapr and
#            leaves it running, and a killed renderer is back in 2 s (F51).
# The apps still open normally; the first launch is a little slower.
DEBLOAT_APPS_SPEC='
youtube.leanback.v4|preload,close
com.webos.app.lgchannels|preload,close
amazon.alexapr|close
'
# Measured 2026-10-22 (RSS + swap):
#   youtube.leanback.v4       60–70 MB, preloaded "semi-full".
#   com.webos.app.lgchannels  LG Channels (LG's ad-supported channels); its
#                             preload reserves 100 MB.
#   amazon.alexapr            the Alexa voice overlay, ~37 MB, loaded at boot
#                             although the mics and the Alexa adapter are
#                             already off (voice module, spec above).
DEBLOAT_SAM_URI=luna://com.webos.applicationManager
DEBLOAT_WAM_URI=luna://com.palm.webappmanager
DEBLOAT_PRELOAD_URI=luna://com.webos.service.preloadmanager

# Per-entry "what feature is lost" — Tier B:
#   iconnectivity — LG phone-pairing / TV Companion helper.
#   amazon-alexa-adapter — Alexa built-in. Deaf already (voice module), but
#     it kept a live AVS session and probed every ~28 s (F48).
#   performer, nlpmanager — leftovers of the voice pipeline.
#   sportsalarm — sports alerts (the sportsAlarm setting is off, yet it ran).
#   familycare — runs as `iotjs .../index.js`, so `pidof` never matches;
#     `cmd:<text>` kills by command line instead.
#   DIAL is NOT touched: the old entry bound discovery-server.js and killed
#     ss.gateway, but ss.gateway is LG's shared host for every JS service
#     (second screen, DIAL, billing, quick cards, ...) and DIAL itself is
#     served by xinetd, so it disabled nothing and broke more (F48).
#   /usr/sbin/sdx — DELIBERATELY NOT NEUTRALISED. See the warning below.
#
# ---------------------------------------------------------------------------
# DO NOT add /usr/sbin/sdx back to DEBLOAT_BINARIES_SPEC.
# Bind-neutralising sdx SILENTLY BREAKS THE TV'S SETTINGS UI (gear button
# dies with no error while surface-manager logs a healthy `visible:true`).
# When sdx is neutralised that line is NEVER emitted — the window is marked
# visible but never initialises: grep QUICKSETTINGS_EDITMODE after a gear
# press (F42). Its egress is already blocked by the `network` module.
# ---------------------------------------------------------------------------
#   /usr/sbin/uploadd|uploadd — log-upload daemon (telemetry). The LS2
#     service com.palm.uploadd is Type=dynamic, so ls-hubd respawns the
#     binary on the next luna-send; only the bind stops it — the re-exec'd
#     process opens /dev/null and exits (F40c).

DEBLOAT_UNITS_STOPPED_LIST="$OYG_ROOT/debloat.units.stopped"
DEBLOAT_PROCS_KILL_LIST="$OYG_ROOT/debloat.procs.kill"

# Per-binary state keys:
#   debloat.bin.<path>.prev   — original mode (octal string)
#   debloat.bin.<path>.bound  — "1" if we bind-mounted /dev/null over it
#   debloat.preload.<appId>.prev — the app's preload switch before the first
#                               harden (True/False)
# debloat.applied                      — "1" once harden completed

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------

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
    spec=$DEBLOAT_BINARIES_SPEC
    _mod_debloat_aggressive && spec="$spec$DEBLOAT_BINARIES_AGGRESSIVE_SPEC"
    printf '%s\n' "$spec" | awk '
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
    case "$proc" in
        cmd:*)
            pat=${proc#cmd:}
            for d in /proc/[0-9]*; do
                [ "${d#/proc/}" = "$$" ] && continue
                tr '\0' ' ' <"$d/cmdline" 2>/dev/null | grep -q -- "$pat" && printf '%s\n' "${d#/proc/}"
            done
            return 0 ;;
    esac
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

    if [ "$(_mod_debloat_is_bound "$path")" = "1" ]; then
        ok "debloat: $path already bind-mounted to /dev/null (idempotent)" >&2
        state_put "debloat.bin.${path}.bound" "1"
        printf 'OK\n'
        return 0
    fi

    # Capture the mode AFTER the is_bound early-return (Bug B). If the
    # path was already bind-mounted, stat would see /dev/null's mode
    # (666), not the binary's real mode. Only sample a live, unmounted
    # binary. `755` fallback is unchanged.
    if [ -z "$orig" ]; then
        orig=$(_mod_debloat_path_mode "$path")
        [ -z "$orig" ] && orig="755"
        state_put "debloat.bin.${path}.prev" "$orig"
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

# _mod_debloat_load_apps_spec — one <appId>|<how> per line.
_mod_debloat_load_apps_spec() {
    printf '%s\n' "$DEBLOAT_APPS_SPEC" | awk 'NF && $1 !~ /^#/ { print $1 }'
}

# _mod_debloat_apps_snapshot — the foreground app, the running apps and the
# preload switches, in three luna calls, so the per-app checks need none.
_mod_debloat_apps_snapshot() {
    DEBLOAT_FG=$(oyg_luna "$DEBLOAT_SAM_URI/getForegroundAppInfo" '{}' | oyg_json "d.get('appId')")
    DEBLOAT_RUNNING=$(oyg_luna "$DEBLOAT_SAM_URI/running" '{}' \
        | oyg_json "[a['id'] for a in d.get('running', [])]")
    DEBLOAT_PRELOAD=$(oyg_luna "$DEBLOAT_PRELOAD_URI/getPreloadPolicy" '{}' \
        | oyg_json "['%s %s' % (a.get('id'), a.get('isEnabled')) for a in d.get('applications', [])]")
}

# _mod_debloat_preload_get <appId> — True/False, empty when the preload
# manager has no entry for the app. Reads the snapshot.
_mod_debloat_preload_get() {
    printf '%s\n' "$DEBLOAT_PRELOAD" | awk -v a="$1" '$1 == a { print $2; exit }'
}

# _mod_debloat_preload_set <appId> <true|false>
_mod_debloat_preload_set() {
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: setPreloadPolicy %s isEnabled=%s\n' "$1" "$2"
        return 0
    fi
    oyg_luna "$DEBLOAT_PRELOAD_URI/setPreloadPolicy" \
        "{\"application\":{\"id\":\"$1\",\"isEnabled\":$2}}" \
        | oyg_json "d.get('returnValue')" | grep -q True
}

# _mod_debloat_app_state <appId> — "foreground", "background", or nothing
# when it is not running. Reads the snapshot.
_mod_debloat_app_state() {
    if [ "$DEBLOAT_FG" = "$1" ]; then
        printf 'foreground'
    elif printf '%s\n' "$DEBLOAT_RUNNING" | grep -qxF -- "$1"; then
        printf 'background'
    fi
}

# _mod_debloat_app_close <appId> — the web-app manager first (the only
# route that closes amazon.alexapr), SAM's closeByAppId as the fallback.
# Takes a fresh snapshot to check.
_mod_debloat_app_close() {
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: killApp %s\n' "$1"
        return 0
    fi
    oyg_luna "$DEBLOAT_WAM_URI/killApp" "{\"appId\":\"$1\"}" >/dev/null
    sleep 1
    _mod_debloat_apps_snapshot
    [ "$(_mod_debloat_app_state "$1")" = "background" ] || return 0
    oyg_luna "$DEBLOAT_SAM_URI/closeByAppId" "{\"id\":\"$1\"}" >/dev/null
    sleep 1
    _mod_debloat_apps_snapshot
    [ "$(_mod_debloat_app_state "$1")" != "background" ]
}

# _mod_debloat_apps_harden — pass 3. Preload off first, so the preload
# manager cannot load the app straight back after the close.
_mod_debloat_apps_harden() {
    arc=0
    _mod_debloat_apps_snapshot
    for spec in $(_mod_debloat_load_apps_spec); do
        app=${spec%%|*}
        how=${spec#*|}
        case ",$how," in *,preload,*)
            cur=$(_mod_debloat_preload_get "$app")
            if [ -z "$cur" ]; then
                ok "debloat: $app — not in the preload list"
            else
                [ -n "$(state_get "debloat.preload.${app}.prev")" ] \
                    || state_put "debloat.preload.${app}.prev" "$cur"
                if [ "$cur" = "False" ]; then
                    ok "debloat: $app — preload already off"
                elif _mod_debloat_preload_set "$app" false; then
                    ok "debloat: $app — preload switched off"
                else
                    err "debloat: $app — could not switch its preload off"
                    arc=1
                fi
            fi
            ;;
        esac
        case ",$how," in *,close,*)
            case "$(_mod_debloat_app_state "$app")" in
                foreground)
                    ok "debloat: $app — on screen, left open" ;;
                background)
                    if _mod_debloat_app_close "$app"; then
                        ok "debloat: $app — closed (it was loaded in the background)"
                    else
                        err "debloat: $app — still loaded after killApp and closeByAppId"
                        arc=1
                    fi ;;
                *)
                    ok "debloat: $app — not loaded" ;;
            esac
            ;;
        esac
    done
    return $arc
}

# _mod_debloat_apps_restore — preload switches back to what they were.
# Closed apps are not reopened: LG loads them again when it wants them.
_mod_debloat_apps_restore() {
    for spec in $(_mod_debloat_load_apps_spec); do
        app=${spec%%|*}
        prev=$(state_get "debloat.preload.${app}.prev")
        [ -n "$prev" ] || continue
        v=false
        [ "$prev" = "True" ] && v=true
        if _mod_debloat_preload_set "$app" "$v"; then
            ok "debloat: $app — preload set back to $v"
        else
            warn "debloat: $app — could not set its preload back to $v (the next boot resets it)"
        fi
        state_drop "debloat.preload.${app}.prev"
    done
}

# -----------------------------------------------------------------------------
# entry points
# -----------------------------------------------------------------------------

# _mod_debloat_aggressive — iot-client is only neutralised with aggressive
# services: the flag now, or iot-client already in the services module's
# boot kill list (how an earlier OYG_AGGRESSIVE=1 run is remembered).
_mod_debloat_aggressive() {
    [ "${OYG_AGGRESSIVE:-0}" = "1" ] && return 0
    grep -qx 'iot-client' "$OYG_ROOT/services.kill" 2>/dev/null
}

# _mod_debloat_retire_stale [all] — binaries this module bound that are no
# longer in the spec (an older spec, or aggressive since turned off; with
# "all", every one) are unbound and their state forgotten.
_mod_debloat_retire_stale() {
    current=""
    [ "${1:-}" = "all" ] || current=$(_mod_debloat_load_binaries_spec | awk -F'|' '{print $1}')
    sed -n -E 's/^debloat\.bin\.(.*)\.(prev|bound)=.*/\1/p' "$OYG_STATE" 2>/dev/null | sort -u |
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        printf '%s\n' "$current" | grep -qxF -- "$path" && continue
        if [ "$(_mod_debloat_is_bound "$path")" = "1" ]; then
            run umount "$path" 2>/dev/null && ok "debloat: $path no longer targeted — unbound"
        fi
        prev=$(state_get "debloat.bin.${path}.prev")
        [ -n "$prev" ] && [ -e "$path" ] && run chmod "$prev" "$path" 2>/dev/null
        state_drop "debloat.bin.${path}.prev"
        state_drop "debloat.bin.${path}.bound"
    done
}

mod_debloat_harden() {
    require_root
    ensure_dirs

    have systemctl || [ "$OYG_DRY_RUN" = "1" ] \
        || { err "debloat: systemctl not found"; return 1; }
    if ! have systemctl && [ "$OYG_DRY_RUN" = "1" ]; then
        warn "debloat: systemctl not found — dry-run will simulate unit states (inactive)"
    fi

    # The boot hook's late pass, for apps LG loads after the hook is done.
    if [ "${OYG_DEBLOAT_APPS_ONLY:-0}" = "1" ]; then
        _mod_debloat_apps_harden
        return $?
    fi

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
        # Record `.prev` ONLY when it is not already present (Bug A).
        # The boot hook re-runs harden --only debloat on every boot, by
        # which time the unit is already stopped; an unguarded write
        # would clobber the true original state with `inactive/...` and
        # silently break restore.
        if [ -z "$(state_get "debloat.unit.${id}.prev")" ]; then
            state_put "debloat.unit.${id}.prev" "${prev_unit_state}|proc=${prev_proc_state}"
        fi

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
    _mod_debloat_retire_stale
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

    # --- pass 3: apps LG keeps loaded in the background ---
    _mod_debloat_apps_harden || rc=1

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
        is_enabled=$(_mod_debloat_query "$unit" is-enabled)

        # Bug C: restore means "return to vendor intent". A unit is
        # restored if EITHER the .prev record says it was active OR
        # the unit is currently `enabled` (systemd would start it on
        # a clean boot). Dry-run stays a no-op for starts — `run`
        # short-circuits systemctl start to a `DRY-RUN:` line.
        start_reason=""
        if [ "$was_active" = "active" ]; then
            start_reason="recorded active"
        elif [ "$is_enabled" = "enabled" ] \
            && [ "$(_mod_debloat_unit_present "$unit")" = "1" ] \
            && [ "$OYG_DRY_RUN" != "1" ]; then
            start_reason="unit is enabled"
        fi

        if [ -n "$start_reason" ]; then
            if _mod_debloat_stop_unit "$unit" 2>/dev/null || true; then
                if [ "$(_mod_debloat_unit_present "$unit")" = "1" ]; then
                    if run systemctl start "$unit" 2>/dev/null; then
                        ok "debloat: $id unit <$unit> started (restored: $start_reason)"
                    else
                        warn "debloat: start $unit failed (will leave stopped)"
                        rc=1
                    fi
                fi
            fi
        else
            ok "debloat: $id left stopped (recorded=$was_active, enabled=$is_enabled)"
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

    _mod_debloat_retire_stale all
    _mod_debloat_apps_restore
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

    # --- background apps ---
    _mod_debloat_apps_snapshot
    for spec in $(_mod_debloat_load_apps_spec); do
        app=${spec%%|*}
        how=${spec#*|}
        case ",$how," in *,preload,*)
            case "$(_mod_debloat_preload_get "$app")" in
                False) print_status OK "$app: preload off" ;;
                True)  print_status FAIL "$app: preload on — LG loads it again after every close" ;;
                *)     print_status N/A "$app: not in the preload list" ;;
            esac
            ;;
        esac
        case ",$how," in *,close,*)
            case "$(_mod_debloat_app_state "$app")" in
                background) print_status FAIL "$app: loaded in the background" ;;
                foreground) print_status OK "$app: on screen (in use)" ;;
                *)          print_status OK "$app: not loaded" ;;
            esac
            ;;
        esac
    done

    if [ "$disabled_count" -gt 0 ]; then
        ok "debloat: $disabled_count target(s) currently disabled"
    fi
}