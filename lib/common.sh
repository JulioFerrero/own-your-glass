OYG_LIB=1

OYG_ROOT=${OYG_ROOT:-/var/lib/own-your-glass}
OYG_STATE="$OYG_ROOT/state"
OYG_BACKUP="$OYG_ROOT/backup"
OYG_LOG="$OYG_ROOT/log.txt"
OYG_WATCHERS="$OYG_ROOT/watchers"
OYG_DRY_RUN=${OYG_DRY_RUN:-0}

umask 077

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
ok()   { printf '[%s] OK   %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; }
err()  { printf '[%s] ERR  %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; }

have() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {
    if [ "$(id -u 2>/dev/null)" != "0" ] && [ "$OYG_DRY_RUN" != "1" ]; then
        err "must be run as root (or use --dry-run)"
        exit 1
    fi
}

# oyg_supported — true on firmware the toolkit has been run on: webOS 10
# (webOS 25) with python3. Otherwise false, with the reason in
# OYG_UNSUPPORTED. OYG_FORCE_UNSUPPORTED=1 accepts an older webOS; nothing
# accepts a missing python3, since the DNS, policy, launcher and debloat
# steps need it. On webOS 4 (BusyBox 1.2x, no python3) the modules half-ran
# and left a TV that could neither restore nor factory reset.
OYG_MIN_WEBOS=10
oyg_supported() {
    OYG_UNSUPPORTED=""
    _s_rel=$(sed -n 's/.*"webos_release"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        /var/run/nyx/os_info.json 2>/dev/null | head -n 1)
    if ! have python3; then
        OYG_UNSUPPORTED="python3 is missing (webOS ${_s_rel:-unknown})"
        return 1
    fi
    case "${_s_rel%%.*}" in
        '' | *[!0-9]*)
            OYG_UNSUPPORTED="cannot read webos_release from /var/run/nyx/os_info.json" ;;
        *)
            [ "${_s_rel%%.*}" -ge "$OYG_MIN_WEBOS" ] && return 0
            OYG_UNSUPPORTED="webOS $_s_rel is older than webOS $OYG_MIN_WEBOS, the only version this toolkit has been run on" ;;
    esac
    [ "${OYG_FORCE_UNSUPPORTED:-0}" = "1" ] || return 1
    warn "$OYG_UNSUPPORTED — continuing (OYG_FORCE_UNSUPPORTED=1)"
    return 0
}

ensure_dirs() {
    [ "$OYG_DRY_RUN" = "1" ] && return 0
    [ -d "$OYG_ROOT" ] && return 0
    if mkdir -p "$OYG_ROOT" "$OYG_BACKUP" "$OYG_WATCHERS" 2>/dev/null; then
        return 0
    fi
    err "cannot create $OYG_ROOT — are you root, or is /var/lib writable here?"
    return 1
}

run() {
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: %s\n' "$*"
        return 0
    fi
    if [ -n "${OYG_LOG:-}" ]; then
        printf '[%s] RUN   %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$OYG_LOG" 2>/dev/null || true
    fi
    "$@"
}

# oyg_luna <uri> <json> — one reply on stdout. stdin is closed: over a
# non-interactive shell luna-send otherwise prints nothing.
oyg_luna() {
    luna-send -n 1 -w 10000 -f "$1" "$2" </dev/null 2>/dev/null
}

# oyg_json <expr> — evaluate a Python expression over the JSON reply on
# stdin (bound to d; json is imported). Lists print one item per line.
oyg_json() {
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
r = eval(sys.argv[1])
if isinstance(r, (list, tuple)):
    print("\n".join(str(x) for x in r))
elif r is not None:
    print(r)
' "$1"
}

# oyg_setting_get <category> <key> — the value from settingsservice;
# booleans print as true/false. Empty if the key is not on this firmware.
oyg_setting_get() {
    oyg_luna luna://com.webos.settingsservice/getSystemSettings \
        "{\"category\":\"$1\",\"keys\":[\"$2\"]}" \
        | oyg_json "(lambda v: v if v is None or isinstance(v, str) else json.dumps(v))(d.get('settings', {}).get('$2'))"
}

# oyg_setting_set <category> <key> <value> — true/false are sent as JSON
# booleans, anything else as a string.
oyg_setting_set() {
    case "$3" in
        true|false) v=$3 ;;
        *) v="\"$3\"" ;;
    esac
    oyg_luna luna://com.webos.settingsservice/setSystemSettings \
        "{\"category\":\"$1\",\"settings\":{\"$2\":$v}}" \
        | oyg_json "d.get('returnValue')" | grep -q True
}

state_put() {
    key=$1; shift
    [ "$OYG_DRY_RUN" = "1" ] && {
        printf 'DRY-RUN state: %s=%s\n' "$key" "$*"
        return 0
    }
    ensure_dirs
    touch "$OYG_STATE" 2>/dev/null || return 1
    tmp=$(mktemp 2>/dev/null) || return 1
    awk -F= -v k="$key" -v v="$*" '
        $1 == k { found = 1; next }
        { print }
        END { print k "=" v }
    ' "$OYG_STATE" >"$tmp" 2>/dev/null && mv "$tmp" "$OYG_STATE"
    rm -f "$tmp" 2>/dev/null
}

state_get() {
    key=$1
    [ -r "$OYG_STATE" ] || return 1
    awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$OYG_STATE"
}

state_drop() {
    key=$1
    [ "$OYG_DRY_RUN" = "1" ] && return 0
    [ -r "$OYG_STATE" ] || return 0
    tmp=$(mktemp 2>/dev/null) || return 1
    awk -F= -v k="$key" '$1!=k' "$OYG_STATE" >"$tmp" 2>/dev/null && mv "$tmp" "$OYG_STATE"
    rm -f "$tmp" 2>/dev/null
}


# oyg_watcher_alive <script> — its pidfile names a live process running <script>
# (the argv check keeps a reused pid from counting).
oyg_watcher_alive() {
    _w_pid=$(cat "$OYG_WATCHERS/$(basename "$1" .sh).pid" 2>/dev/null) || return 1
    [ -n "$_w_pid" ] && kill -0 "$_w_pid" 2>/dev/null || return 1
    tr '\0' '\n' <"/proc/$_w_pid/cmdline" 2>/dev/null | grep -qxF -- "$1"
}

# oyg_watcher_start <script> — start <script> in the background unless running.
oyg_watcher_start() {
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: start watcher %s\n' "$1"
        return 0
    fi
    [ -r "$1" ] || { warn "watcher missing: $1"; return 1; }
    oyg_watcher_alive "$1" && return 0
    mkdir -p "$OYG_WATCHERS" || return 1
    nohup sh "$1" </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" >"$OYG_WATCHERS/$(basename "$1" .sh).pid"
    ok "watcher started: $1 (pid $!)"
}

# oyg_watcher_stop <script> — TERM the running copy and drop its pidfile.
oyg_watcher_stop() {
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: stop watcher %s\n' "$1"
        return 0
    fi
    _w_pidfile="$OYG_WATCHERS/$(basename "$1" .sh).pid"
    if oyg_watcher_alive "$1"; then
        kill -TERM "$_w_pid" 2>/dev/null
        _w_n=0
        while [ "$_w_n" -lt 10 ] && kill -0 "$_w_pid" 2>/dev/null; do
            sleep 1
            _w_n=$((_w_n + 1))
        done
        ok "watcher stopped: $1"
    fi
    rm -f "$_w_pidfile"
}

# oyg_run_lock — serialise harden/restore runs (boot hook, panel, watchers).
# mkdir is atomic; a lock whose holder has died is taken over. It lives on
# tmpfs: under $OYG_ROOT, a lock left by a reboot mid-run would name a pid
# that some other process can own after boot, and every run would wait on it.
OYG_RUN_LOCK=/tmp/oyg-run.lock
oyg_run_lock() {
    _w_n=0
    while ! mkdir "$OYG_RUN_LOCK" 2>/dev/null; do
        _w_holder=$(cat "$OYG_RUN_LOCK/pid" 2>/dev/null)
        # No pid after 5 s means the holder died between mkdir and writing it.
        if { [ -n "$_w_holder" ] && ! kill -0 "$_w_holder" 2>/dev/null; } \
            || { [ -z "$_w_holder" ] && [ "$_w_n" -ge 5 ]; }; then
            rm -rf "$OYG_RUN_LOCK"
            continue
        fi
        _w_n=$((_w_n + 1))
        [ "$_w_n" -ge 600 ] && { err "another oyg run still holds $OYG_RUN_LOCK"; return 1; }
        sleep 1
    done
    printf '%s\n' "$$" >"$OYG_RUN_LOCK/pid"
    trap 'rm -rf "$OYG_RUN_LOCK"' EXIT
}

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

print_status() {
    state=$1; detail=$2
    printf '%-8s %s\n' "$state" "$detail"
}

# ---------------------------------------------------------------------------
# oyg_guard_connman_route — fails loudly if the ConnMan signal/reload route
# is reintroduced into the DNS scripts. See the post-mortem block in
# scripts/dns.sh: editing connman's service settings and nudging connmand
# took this TV off the network for ~30 minutes (`systemctl reload connman`
# has NO ExecReload on this device, so systemd fell back to SIGHUP, which
# tore the Wi-Fi down). The forbidden patterns are assembled from fragments
# so this guard's own source never contains them contiguously. Any
# POST-MORTEM block in a scanned file is stripped first, so the incident
# write-up may quote the exact commands.
# ---------------------------------------------------------------------------
oyg_guard_connman_route() {
    _g_hup="kill -""HUP"
    _g_shup="kill -s ""HUP"
    _g_allhup="killall -""HUP"
    _g_reload="systemctl re""load connman"
    _g_restart="systemctl re""start connman"
    _g_ns="Nameservers=127.0.0.2"";"
    _g_bad=0
    for _g_f in "$@"; do
        [ -r "$_g_f" ] || continue
        _g_tmp=$(mktemp 2>/dev/null) || continue
        sed '/^# ==== POST-MORTEM/,/^# ==== END POST-MORTEM/d' "$_g_f" \
            >"$_g_tmp" 2>/dev/null || true
        for _g_p in "$_g_hup" "$_g_shup" "$_g_allhup" "$_g_reload" "$_g_restart" "$_g_ns"; do
            if grep -F -e "$_g_p" "$_g_tmp" >/dev/null 2>&1; then
                err "guard: FORBIDDEN ConnMan pattern '$_g_p' found in $_g_f — the ConnMan route took this TV offline for ~30 min once; NEVER signal/reload/restart connmand (see scripts/dns.sh post-mortem)"
                _g_bad=1
            fi
        done
        rm -f "$_g_tmp" 2>/dev/null || true
    done
    [ "$_g_bad" = "0" ]
}
