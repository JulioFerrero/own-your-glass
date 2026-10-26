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

# `type`, not `command -v`: ash builds without CONFIG_ASH_CMDCMD (OpenEmbedded's
# BusyBox 1.24.1, the webOS 4 era) have no `command`, and every tool looked
# missing.
have() {
    type "$1" >/dev/null 2>&1
}

# oyg_retire_backup <file> — after a restore has put <file> back, move it to
# <file>.restored: kept for the record, and the next harden takes a fresh
# backup instead of reviving this one over changes made since.
oyg_retire_backup() {
    [ -e "$1" ] || return 0
    [ "$OYG_DRY_RUN" = "1" ] && { printf 'DRY-RUN: mv %s %s.restored\n' "$1" "$1"; return 0; }
    mv -f "$1" "$1.restored" 2>/dev/null
}

# oyg_chmod_back <path> <mode> — put <path> back to <mode>; nothing to do if
# it already has it. Binaries on the read-only /usr refused harden's chmod
# 000 too, so for them this is the common case, not a failure.
oyg_chmod_back() {
    _c_cur=$(stat -c '%a' "$1" 2>/dev/null | sed 's/^0*//')
    [ -n "$_c_cur" ] && [ "$_c_cur" = "$(printf '%s' "$2" | sed 's/^0*//')" ] && return 0
    run chmod "$2" "$1" 2>/dev/null
}

# oyg_mode_like <file> <tmp> [<original>] — give <tmp> the mode of the
# backup of the original if given, else of <file>, else 0644, before it
# replaces <file>. Temp files are 0600 under the toolkit's umask, LG's files
# are 0644, and a file an older version rewrote may still carry its 0600.
oyg_mode_like() {
    _m_mode=""
    [ -n "${3:-}" ] && [ -f "$3" ] && ! grep -q '^SENTINEL=absent' "$3" 2>/dev/null \
        && _m_mode=$(stat -c '%a' "$3" 2>/dev/null)
    [ -n "$_m_mode" ] || _m_mode=$(stat -c '%a' "$1" 2>/dev/null)
    chmod "${_m_mode:-644}" "$2" 2>/dev/null
    return 0
}

# oyg_nap <seconds> — sleep, fractions allowed; BusyBox built without
# fractional sleep sleeps a whole second instead of not at all.
oyg_nap() {
    sleep "$1" 2>/dev/null || sleep 1
}

# oyg_pids_matching <text> — pids whose command line contains <text>, like
# pgrep -f, which some BusyBox builds leave out. OYG_PROC: tests only.
oyg_pids_matching() {
    for _p_d in "${OYG_PROC:-/proc}"/[0-9]*; do
        [ "${_p_d##*/}" = "$$" ] && continue
        tr '\0' ' ' <"$_p_d/cmdline" 2>/dev/null | grep -qF -- "$1" \
            && printf '%s\n' "${_p_d##*/}"
    done
    return 0
}

require_root() {
    if [ "$(id -u 2>/dev/null)" != "0" ] && [ "$OYG_DRY_RUN" != "1" ]; then
        err "must be run as root (or use --dry-run)"
        exit 1
    fi
}

# oyg_supported — true on firmware the toolkit has been run on: webOS 10
# (webOS 25). Otherwise false, with the reason in OYG_UNSUPPORTED.
# OYG_FORCE_UNSUPPORTED=1 accepts an older webOS, and so does the file
# OYG_ALLOW_UNSUPPORTED (testing mode, left by
# 'install-app.sh' run with OYG_FORCE_UNSUPPORTED=1), so that the app's
# Apply hardening and the boot hook take it too; OYG_FORCE_UNSUPPORTED=0
# overrides the file. node is required (the DNS
# sink); every webOS TV ships it. On webOS 4 (BusyBox 1.24, no python3) an
# older version half-ran and left a TV that could neither restore nor
# factory reset (F52).
OYG_MIN_WEBOS=10
OYG_ALLOW_UNSUPPORTED="$OYG_ROOT/allow-unsupported"
oyg_supported() {
    OYG_UNSUPPORTED=""
    _s_rel=$(sed -n 's/.*"webos_release"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        /var/run/nyx/os_info.json 2>/dev/null | head -n 1)
    if ! have node; then
        OYG_UNSUPPORTED="node is missing (webOS ${_s_rel:-unknown})"
        return 1
    fi
    case "${_s_rel%%.*}" in
        '' | *[!0-9]*)
            OYG_UNSUPPORTED="cannot read webos_release from /var/run/nyx/os_info.json" ;;
        *)
            [ "${_s_rel%%.*}" -ge "$OYG_MIN_WEBOS" ] && return 0
            OYG_UNSUPPORTED="webOS $_s_rel is older than webOS $OYG_MIN_WEBOS, the only version this toolkit has been run on" ;;
    esac
    _s_force=${OYG_FORCE_UNSUPPORTED:-}
    [ -z "$_s_force" ] && [ -e "$OYG_ALLOW_UNSUPPORTED" ] && _s_force=1
    [ "$_s_force" = "1" ] || return 1
    warn "$OYG_UNSUPPORTED — continuing in testing mode (untested firmware)"
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

# oyg_jflat — JSON on stdin as one "<path><TAB><value>" line per scalar,
# e.g. "settings.hbbTV	off" or "apps[3].id	com.x". Strings lose their
# quotes (\" \\ \/ decoded, \n \t \r become spaces); true, false, null and
# numbers stay as written; an empty array or object prints as [] or {}.
# BusyBox awk, no Python: works on any webOS. It walks one line at a time,
# which luna-send -f output keeps short.
oyg_jflat() {
    awk '
    function path(   p, i) {
        p = ""
        # No "name (" anywhere: awk before BusyBox 1.30 reads it as a call.
        for (i = 1; i <= d; i++) {
            if (t[i] == "a") p = p "[" n[i] "]"
            else if (p == "") p = k[i]
            else p = p "." k[i]
        }
        return p
    }
    function value(v) {
        if (d > 0) m[d]++
        if (d > 0 && t[d] == "a") n[d]++
        printf "%s\t%s\n", path(), v
        if (d > 0 && t[d] == "o") hk[d] = 0
    }
    function unesc(s) {
        gsub(/\\\\/, "\002", s); gsub(/\\"/, "\"", s); gsub(/\\\//, "/", s)
        gsub(/\\[ntr]/, " ", s); gsub(/\002/, "\\", s)
        return s
    }
    {
        l = $0
        while (l != "") {
            c = substr(l, 1, 1)
            if (c == " " || c == "\t" || c == "\r" || c == ":" || c == ",") {
                l = substr(l, 2)
            } else if (c == "\"") {
                if (!match(l, /^"([^"\\]|\\.)*"/)) { l = ""; break }
                s = unesc(substr(l, 2, RLENGTH - 2)); l = substr(l, RLENGTH + 1)
                if (d > 0 && t[d] == "o" && !hk[d]) { k[d] = s; hk[d] = 1 } else value(s)
            } else if (c == "{" || c == "[") {
                if (d > 0) m[d]++
                if (d > 0 && t[d] == "a") n[d]++
                d++; t[d] = (c == "{") ? "o" : "a"; n[d] = -1; hk[d] = 0; m[d] = 0
                l = substr(l, 2)
            } else if (c == "}" || c == "]") {
                e = (m[d] == 0); ty = t[d]
                d--
                if (e && ty == "a") printf "%s\t[]\n", path()
                if (e && ty == "o") printf "%s\t{}\n", path()
                if (d > 0 && t[d] == "o") hk[d] = 0
                l = substr(l, 2)
            } else if (match(l, /^[-+.0-9A-Za-z]+/)) {
                value(substr(l, 1, RLENGTH)); l = substr(l, RLENGTH + 1)
            } else {
                l = substr(l, 2)    # anything else: skip it, never loop
            }
        }
    }'
}

# oyg_jget <path> — the value at <path> (oyg_jflat naming) in the JSON on
# stdin; empty when absent.
oyg_jget() {
    oyg_jflat | awk -v p="$1" 'index($0, p "\t") == 1 { print substr($0, length(p) + 2); exit }'
}

# oyg_jlist <array> <field> [<field> ...] — for every element of <array>,
# its fields on one line, space-separated, in the order given.
oyg_jlist() {
    oyg_jflat | awk -v a="$1" -v fs="$*" '
        BEGIN { nf = split(fs, f, " ") }
        index($0, a "[") == 1 {
            rest = substr($0, length(a) + 2)
            i = substr(rest, 1, index(rest, "]") - 1)
            rest = substr(rest, length(i) + 3)
            tab = index(rest, "\t")
            key = substr(rest, 1, tab - 1)
            if (!(i in seen)) { seen[i] = 1; order[++m] = i }
            v[i, key] = substr(rest, tab + 1)
        }
        END {
            for (j = 1; j <= m; j++) {
                line = ""
                for (x = 2; x <= nf; x++) {
                    if (x > 2) line = line " "
                    line = line v[order[j], f[x]]
                }
                print line
            }
        }'
}

# oyg_setting_get <category> <key> — the value from settingsservice;
# booleans print as true/false. Empty if the key is not on this firmware.
oyg_setting_get() {
    oyg_luna luna://com.webos.settingsservice/getSystemSettings \
        "{\"category\":\"$1\",\"keys\":[\"$2\"]}" \
        | oyg_jget "settings.$2"
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
        | oyg_jok
}

# oyg_jok — true when the luna reply on stdin has "returnValue": true.
oyg_jok() {
    [ "$(oyg_jget returnValue)" = "true" ]
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
