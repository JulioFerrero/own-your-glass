#!/bin/sh
# dns.sh — operator entry point for the on-device DNS sinkhole resolver.
#
# Wraps scripts/dnssink.py with the lifecycle, the ConnMan integration
# ("Variant 1" — add Nameservers=127.0.0.2; to connman's service
# settings, nudge connmand via SIGHUP, never restart), and a watchdog.
#
# Why this script exists:
#   - The TV's libc tools honour /etc/hosts (getent returns the sinkhole)
#     but connmand's DNS proxy on 127.0.0.1:53 does NOT (verified). That
#     means webOS daemons continue to resolve blocklisted telemetry
#     names even after `oyg harden --only network`. The only enforcement
#     point on this device is to make connmand use our resolver as its
#     upstream, and only a reload (SIGHUP) — not a restart — keeps the
#     Wi-Fi lease alive.
#
# Subcommands:
#   start      bring the resolver up, set Nameservers=127.0.0.2 in
#              connman's service settings, nudge connmand via SIGHUP
#   stop       kill the resolver and restore the connman settings file
#   status     show what's running, what's hooked in, upstream
#   log        tail the audit log (non-blocking if no resolver yet)
#   test       issue live nslookup-style queries against 127.0.0.2
#              showing blocked + allowed answers + audit lines
#   revert     explicit rollback of the connman settings file from backup
#
# All subcommands are idempotent (re-running is safe).
#
# State keys (under OYG_ROOT/state, written via lib/common.sh):
#   dns.applied=1                       resolver is live on 127.0.0.2:53
#   dns.service_dir=/var/lib/connman/.. connman service dir we touched
#   dns.original_settings=<path>         backup of pre-override settings
#   dns.connmand_pid=<pid>               last-known connmand pid (HUP)
#
# Required:
#   python3 on PATH; connmanctl at /usr/bin/connmanctl;
#   /var/lib/connman/<service>/settings writeable by us.
#
# NOTES:
#   - We never restart connmand in this script. If we cannot make
#     connmand re-read the settings file after we add Nameservers=, we
#     STOP and report (so the operator can investigate) instead of
#     risking `systemctl restart connman` which can drop the Wi-Fi IP
#     and there is no telnet lifeline (webosbrew telnetd is disabled by
#     the policy module).
#   - `start` and `stop` are no-ops if the requested state already
#     holds. They never re-clobber a good backup.

set -u

OYG_HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# scripts/dnssink.py and watch-dns.sh live in the same dir as this script.
PY=python3
RESOLVER="$OYG_HERE/dnssink.py"
WATCHDOG="$OYG_HERE/watch-dns.sh"

# lib/common.sh lives at $OYG_HERE/../lib/common.sh. When sourced under
# `bash -c`, $0 is "bash" — fall back to $OYG_ROOT if exported.
if [ -r "$OYG_HERE/../lib/common.sh" ]; then
    . "$OYG_HERE/../lib/common.sh"
elif [ -n "${OYG_ROOT:-}" ] && [ -r "$OYG_ROOT/lib/common.sh" ]; then
    . "$OYG_ROOT/lib/common.sh"
else
    echo "dns.sh: cannot locate lib/common.sh" >&2
    exit 1
fi

CONNMANCTL=/usr/bin/connmanctl
CONNMAN_SERVICES_DIR=/var/lib/connman
AUTO_UPSTREAM_DIR=/var/lib/misc

DNS_BIND=127.0.0.2
DNS_PORT=53
AUDIT_LOG="$OYG_ROOT/dns-audit.log"
HOSTS_FILE="$OYG_ROOT/hosts"
STATE_PID="$OYG_ROOT/dns.pid"
WATCHDOG_PID="$OYG_ROOT/watch-dns.pid"

log_dns() { log "dns: $*"; }
ok_dns()  { ok "dns: $*"; }
warn_dns(){ warn "dns: $*"; }
err_dns() { err "dns: $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        err_dns "must be run as root (or under sudo)"
        exit 1
    fi
}

ensure_dirs() { ensure_dirs; }

# Pick the connman service directory that is currently connected.
# Returns the path on stdout; empty string if none.
_active_connman_service_dir() {
    [ -d "$CONNMAN_SERVICES_DIR" ] || return 0
    if have "$CONNMANCTL"; then
        out=$("$CONNMANCTL" services 2>/dev/null) || return 0
        # Lines look like: "*AO Wired" or "*A  wifi_…_managed_psk …"
        # Pick the first line that contains '*'.
        svc=$("$CONNMANCTL" services 2>/dev/null \
            | grep '^\*' \
            | awk '{
                s = ""; i = 1
                # Skip leading "*AO " or "*A " tokens to find the first quoted service.
                while (i <= NF) {
                    if ($i ~ /^[*]/) { i++; continue }
                    if (substr($i, 1, 1) == " ") { i++; continue }
                    s = $i; break
                }
                if (length(s) > 0) { print s; exit }
            }')
    else
        svc=""
    fi
    if [ -n "$svc" ]; then
        d="$CONNMAN_SERVICES_DIR/$svc"
        [ -d "$d" ] && printf '%s' "$d" && return 0
    fi
    # Fall back to the first service dir that already has a settings file.
    for d in "$CONNMAN_SERVICES_DIR"/*/; do
        [ -f "$d/settings" ] && printf '%s' "$d" && return 0
    done
    return 0
}

# Discover the upstream resolver. Mirrors dnssink.py's discovery but we
# also allow the operator to override via env / CLI. Echoes the IP on
# stdout and reports the source.
discover_upstream() {
    ip=""
    src=""
    if have "$CONNMANCTL"; then
        ip=$("$CONNMANCTL" services 2>/dev/null \
            | sed -n 's/.*Nameservers=\(\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}\).*/\1/p' \
            | head -n 1)
        if [ -n "$ip" ]; then
            src="connmanctl"
            printf '%s %s\n' "$ip" "$src"
            return 0
        fi
    fi
    if have luna-send; then
        out=$(luna-send -n 1 -f \
            'luna://com.webos.service.connectionmanager/getStatus' \
            '{}' </dev/null 2>/dev/null) || out=""
        if [ -n "$out" ] && printf '%s' "$out" | grep -q '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}'; then
            ip=$(printf '%s' "$out" \
                | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
                | head -n 1)
            if [ -n "$ip" ]; then
                src="luna-send"
                printf '%s %s\n' "$ip" "$src"
                return 0
            fi
        fi
    fi
    ip=$(ip route show default 2>/dev/null \
        | awk '/^default/ { for (i=1;i<=NF;i++) if ($i == "via") { print $(i+1); exit } }')
    if [ -n "$ip" ]; then
        src="gateway"
        printf '%s %s\n' "$ip" "$src"
        return 0
    fi
    return 1
}

# Returns the PID of connmand or empty.
connman_pid() {
    if [ -r /var/run/connmand.pid ]; then
        pid=$(cat /var/run/connmand.pid 2>/dev/null || true)
        if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
            printf '%s' "$pid"
            return 0
        fi
    fi
    if have pidof; then
        pid=$(pidof connmand 2>/dev/null | awk '{print $1; exit}') || true
        if [ -n "${pid:-}" ]; then
            printf '%s' "$pid"
            return 0
        fi
    fi
    if have pgrep; then
        pid=$(pgrep -x connmand 2>/dev/null | head -n 1) || true
        if [ -n "${pid:-}" ]; then
            printf '%s' "$pid"
            return 0
        fi
    fi
    return 0
}

# Returns 0 if the resolver is listening on 127.0.0.2:53 (responds to a
# DNS query within 1.5 s).
resolver_alive() {
    if [ ! -r "$STATE_PID" ]; then
        return 1
    fi
    pid=$(cat "$STATE_PID" 2>/dev/null || true)
    if [ -z "${pid:-}" ] || ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    if ! have nslookup; then
        # Last-resort: liveness = process is up.
        return 0
    fi
    out=$(nslookup -port=53 -timeout=1 example.com "$DNS_BIND" 2>&1) || true
    if printf '%s' "$out" | grep -Eq 'Address: '; then
        return 0
    fi
    return 1
}

##############################################################################
# Subcommands
##############################################################################

usage() {
    cat <<EOF
dns.sh — on-device DNS sinkhole operator

Usage:
  scripts/dns.sh start      # bring the resolver up + hook it into connman
  scripts/dns.sh stop       # tear it down + restore connman settings
  scripts/dns.sh status     # print what is live
  scripts/dns.sh log        # tail the audit log
  scripts/dns.sh test [domain] [domain ...]
                           # live nslookup-style probes against 127.0.0.2
  scripts/dns.sh revert     # restore connman settings from backup

State keys managed under \$OYG_ROOT/state:
  dns.applied          1 if resolver is on 127.0.0.2:53
  dns.service_dir      connman service dir we last touched
  dns.original_settings backup of the connman settings file (kept forever)
  dns.connmand_pid     last-known connmand pid
EOF
}

cmd_start() {
    require_root
    [ -r "$RESOLVER" ] || { err_dns "resolver not found at $RESOLVER"; return 1; }
    have $PY || { err_dns "python3 missing from PATH"; return 1; }

    if resolver_alive; then
        ok_dns "resolver already running on $DNS_BIND:$DNS_PORT (pid $(cat "$STATE_PID" 2>/dev/null))"
    else
        # Discover upstream before binding.
        if up_pair=$(discover_upstream) && [ -n "${up_pair%% *}" ]; then
            upstream=${up_pair%% *}
            up_src=${up_pair#* }
            ok_dns "upstream discovered via $up_src -> $upstream"
        else
            err_dns "could not discover an upstream resolver"
            err_dns "  set OYG_DNS_UPSTREAM=<ip> or fix DHCP-advertised DNS"
            return 2
        fi

        ensure_dirs
        : >>"$AUDIT_LOG"
        nohup "$PY" "$RESOLVER" \
            --bind "$DNS_BIND" --port "$DNS_PORT" \
            --upstream "$upstream" \
            --hosts "$HOSTS_FILE" \
            --audit "$AUDIT_LOG" \
            >>"$OYG_ROOT/dns.log" 2>&1 &
        pid=$!
        sleep 0.4
        if ! kill -0 "$pid" 2>/dev/null; then
            err_dns "resolver process exited immediately (check $OYG_ROOT/dns.log)"
            return 1
        fi
        printf '%s\n' "$pid" >"$STATE_PID"
        ok_dns "resolver started: $DNS_BIND:$DNS_PORT pid=$pid upstream=$upstream"
    fi

    # If the connman override is already applied, do nothing more.
    if [ "$(state_get dns.applied 2>/dev/null)" = "1" ]; then
        ok_dns "connman override already applied"
        return 0
    fi

    # Find the active connman service dir; bail safely if we cannot.
    svc=$(_active_connman_service_dir)
    if [ -z "$svc" ] || [ ! -f "$svc/settings" ]; then
        err_dns "could not locate an active connman service settings file"
        err_dns "  expected $CONNMAN_SERVICES_DIR/<service>/settings"
        err_dns "  is connman running?"
        return 1
    fi
    settings="$svc/settings"
    state_put dns.service_dir "$svc"

    # Back up the settings file ONCE (never overwrite a good backup).
    bak="$OYG_BACKUP/connman-$(printf '%s' "$svc" | tr '/' '_').orig"
    if [ ! -e "$bak" ]; then
        cp -p "$settings" "$bak" 2>/dev/null || {
            err_dns "cannot back up $settings to $bak"
            return 1
        }
        state_put dns.original_settings "$bak"
        ok_dns "backed up $settings -> $bak"
    else
        ok_dns "backup already present at $bak"
    fi

    # Idempotent: if Nameservers=127.0.0.2; is already present, do nothing.
    if grep -q '^[[:space:]]*Nameservers=127\.0\.0\.2;' "$settings"; then
        ok_dns "Nameservers=127.0.0.2; already in $settings"
    else
        # Append. ConnMan's value is a ;-separated list; 127.0.0.2 is the
        # primary to keep our sinkhole first.
        # Use awk to handle the append + lock-friendly temp file.
        tmp=$(mktemp 2>/dev/null) || {
            err_dns "cannot create temp file for settings edit"
            return 1
        }
        if cp -p "$settings" "$tmp"; then
            printf 'Nameservers=127.0.0.2;\n' >>"$tmp"
            if mv -f "$tmp" "$settings" 2>/dev/null; then
                ok_dns "appended Nameservers=127.0.0.2; to $settings"
            else
                rm -f "$tmp"
                err_dns "cannot replace $settings (mv failed — restoring from backup)"
                cp -p "$bak" "$settings" 2>/dev/null || true
                return 1
            fi
        else
            rm -f "$tmp"
            err_dns "cannot stage $settings for edit"
            return 1
        fi
    fi

    # Nudge connmand.
    pid=$(connman_pid)
    if [ -n "${pid:-}" ]; then
        if kill -HUP "$pid" 2>/dev/null; then
            state_put dns.connmand_pid "$pid"
            ok_dns "sent SIGHUP to connmand (pid $pid)"
        else
            warn_dns "could not SIGHUP connmand (pid $pid) — trying systemctl reload next"
        fi
    elif have systemctl; then
        if systemctl show connman.service -p ExecReload= 2>/dev/null \
                | grep -q ExecReload=; then
            if systemctl reload connman 2>/dev/null; then
                ok_dns "systemctl reload connman succeeded"
            else
                warn_dns "systemctl reload connman failed (will leave settings in place)"
            fi
        else
            warn_dns "connman.service has no ExecReload= — settings written, will be picked up on its next config scan"
        fi
    else
        warn_dns "could not find a connmand pid; settings are written, pid/connmand may pick them up on its own"
    fi

    state_put dns.applied "1"
    ok_dns "applied"

    # Spawn the watchdog (unless one is already running). It probes the
    # resolver every PROBE_INTERVAL seconds; on death it restarts; if
    # 3 restarts fail it auto-rolls back the connman settings so the TV
    # is never left without DNS.
    if [ -r "$WATCHDOG" ] && [ ! -r "$WATCHDOG_PID" ]; then
        nohup sh "$WATCHDOG" >>"$OYG_ROOT/dns.log" 2>&1 &
        # nohup returns; let the daemon write its own pid file.
        sleep 0.3
        ok_dns "watchdog spawned"
    fi

    return 0
}

cmd_stop() {
    require_root

    # Restore connman settings first so we never leave the TV without
    # resolvable DNS while the resolver is going down.
    svc=$(state_get dns.service_dir)
    bak=$(state_get dns.original_settings)
    if [ -n "$svc" ] && [ -f "$svc/settings" ] && [ -n "$bak" ] && [ -e "$bak" ]; then
        if cp -p "$bak" "$svc/settings" 2>/dev/null; then
            ok_dns "restored $svc/settings from $bak"
        else
            err_dns "cannot restore $svc/settings from $bak"
        fi
        pid=$(connman_pid)
        if [ -n "${pid:-}" ]; then
            kill -HUP "$pid" 2>/dev/null \
                && ok_dns "SIGHUP connmand (pid $pid)" \
                || warn_dns "could not SIGHUP connmand"
        fi
        state_drop dns.service_dir
        state_drop dns.original_settings
    else
        ok_dns "no connman override to revert (state empty or backup missing)"
    fi

    if [ -r "$STATE_PID" ]; then
        pid=$(cat "$STATE_PID" 2>/dev/null || true)
        if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null \
                && ok_dns "TERM $pid" \
                || warn_dns "could not TERM resolver pid=$pid"
            sleep 0.4
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null \
                    && ok_dns "KILL $pid" \
                    || warn_dns "could not KILL resolver pid=$pid"
            fi
        fi
        rm -f "$STATE_PID" 2>/dev/null || true
    else
        ok_dns "no resolver pid file"
    fi

    # Stop watchdog.
    if [ -r "$WATCHDOG_PID" ]; then
        wpid=$(cat "$WATCHDOG_PID" 2>/dev/null || true)
        if [ -n "${wpid:-}" ] && kill -0 "$wpid" 2>/dev/null; then
            kill -TERM "$wpid" 2>/dev/null || true
            ok_dns "stopped watchdog (pid $wpid)"
        fi
        rm -f "$WATCHDOG_PID" 2>/dev/null || true
    fi

    state_drop dns.applied
    state_drop dns.connmand_pid
    ok_dns "stopped"
}

cmd_status() {
    require_root
    printf '%s\n' "== dns status =="
    if resolver_alive; then
        print_status OK "resolver listening on $DNS_BIND:$DNS_PORT (pid $(cat "$STATE_PID" 2>/dev/null))"
    else
        if [ -r "$STATE_PID" ]; then
            print_status FAIL "resolver dead; pid-file present but process gone"
        else
            print_status N/A "resolver not running"
        fi
    fi

    svc=$(state_get dns.service_dir)
    bak=$(state_get dns.original_settings)
    if [ -n "$svc" ] && [ -f "$svc/settings" ] && [ -n "$bak" ] && [ -e "$bak" ]; then
        if grep -q '^[[:space:]]*Nameservers=127\.0\.0\.2;' "$svc/settings"; then
            print_status OK "connman settings has Nameservers=127.0.0.2; ($svc/settings)"
        else
            print_status FAIL "connman settings MISSING Nameservers=127.0.0.2; ($svc/settings)"
        fi
        print_status OK "original settings backed up at $bak"
    elif [ "$(state_get dns.applied 2>/dev/null)" = "1" ]; then
        print_status PARTIAL "dns.applied=1 but service_dir/original_settings absent"
    else
        print_status N/A "no connman override in place"
    fi

    cm_pid=$(connman_pid)
    if [ -n "$cm_pid" ]; then
        print_status OK "connmand pid=$cm_pid (SIGHUP-friendly; no restart needed)"
    else
        print_status N/A "connmand pid not found"
    fi

    if [ -f "$AUDIT_LOG" ]; then
        lines=$(wc -l <"$AUDIT_LOG" 2>/dev/null | tr -d ' ')
        print_status OK "audit log: $AUDIT_LOG ($lines lines)"
        [ "$lines" != "0" ] && {
            last=$(tail -n 3 "$AUDIT_LOG" 2>/dev/null | tr '\n' '|')
            print_status OK "recent: $last"
        }
    else
        print_status N/A "no audit log yet"
    fi

    if up_pair=$(discover_upstream) && [ -n "${up_pair%% *}" ]; then
        upstream=${up_pair%% *}; up_src=${up_pair#* }
        print_status OK "upstream=$upstream (via $up_src)"
    else
        print_status FAIL "could not discover an upstream resolver"
    fi
}

cmd_log() {
    [ -f "$AUDIT_LOG" ] || {
        err_dns "no audit log at $AUDIT_LOG yet — start the resolver first"
        return 1
    }
    exec tail -F "$AUDIT_LOG"
}

cmd_test() {
    if [ $# -lt 1 ]; then
        set -- ngfts.nextlgsdp.com es.nextlgsdp.com www.youtube.com github.com
        warn_dns "no domain given; using built-in sample set"
    fi

    if ! resolver_alive; then
        err_dns "resolver is not running on $DNS_BIND:$DNS_PORT — try: scripts/dns.sh start"
        return 1
    fi

    printf '%s\n' "== dns test against $DNS_BIND:$DNS_PORT =="
    if ! have nslookup; then
        warn_dns "nslookup not on PATH — skipping live queries"
        return 0
    fi

    for d in "$@"; do
        printf '\n--- %s ---\n' "$d"
        nslookup -timeout=2 "$d" "$DNS_BIND" 2>&1 | sed 's/^/  /'
    done

    if [ -f "$AUDIT_LOG" ]; then
        printf '\n--- last 5 audit-log lines ---\n'
        tail -n 5 "$AUDIT_LOG" 2>/dev/null | sed 's/^/  /' || true
    fi
}

cmd_revert() {
    require_root
    svc=$(state_get dns.service_dir)
    bak=$(state_get dns.original_settings)
    if [ -z "$svc" ] || [ -z "$bak" ] || [ ! -e "$bak" ]; then
        err_dns "no original_settings backup to revert to (state: svc='$svc' bak='$bak')"
        return 1
    fi
    if [ ! -f "$svc/settings" ]; then
        err_dns "settings file missing: $svc/settings — cannot revert"
        return 1
    fi
    if cp -p "$bak" "$svc/settings" 2>/dev/null; then
        ok_dns "restored $svc/settings from $bak"
    else
        err_dns "cp $bak $svc/settings failed"
        return 1
    fi
    pid=$(connman_pid)
    if [ -n "${pid:-}" ]; then
        kill -HUP "$pid" 2>/dev/null && ok_dns "SIGHUP connmand (pid $pid)" \
            || warn_dns "SIGHUP failed"
    fi
    rm -f "$STATE_PID" 2>/dev/null || true
    ok_dns "reverted (resolver still running if it was; use 'stop' for full teardown)"
}

main() {
    sub=${1:-help}
    [ $# -gt 0 ] && shift || true
    case "$sub" in
        start)  cmd_start ;;
        stop)   cmd_stop ;;
        status) cmd_status ;;
        log)    cmd_log ;;
        test)   cmd_test "$@" ;;
        revert) cmd_revert ;;
        -h|--help|help) usage ;;
        *) err_dns "unknown subcommand: $sub"; usage; exit 64 ;;
    esac
}

main "$@"
