#!/bin/sh
# dns.sh — operator entry point for the on-device DNS sinkhole resolver.
#
# ==== POST-MORTEM — WHY THERE IS NO CONNMAN CODE HERE ANYMORE ====
# Editing ConnMan's service settings + nudging connmand TOOK THE TV OFF
# THE NETWORK for ~30 min: (1) the dir-selection grabbed the p2p_pseudo
# service, not the wifi service; (2) `systemctl reload connman` has no
# ExecReload → SIGHUP → on this build that tears the Wi-Fi down; the
# settings file was byte-identical afterwards — the SIGNAL alone did it.
# HARD RULE: NEVER signal, reload or restart connmand from this toolkit.
# oyg_guard_connman_route (lib/common.sh) fails loudly if any forbidden
# pattern (kill -HUP / systemctl reload|restart connman /
# Nameservers=127.0.0.2;) reappears here.
# ==== END POST-MORTEM ====
#
# Hook-in (resolv.conf bind-mount; no daemon interaction): a managed file
# lists the sink FIRST (bind from $OYG_ROOT/dns.bind: 127.0.0.2 default,
# 127.0.0.1 under Variant C) and the real upstream as fallback; the
# resolver is PROVEN answering BEFORE the override mounts (no no-DNS
# window); the watchdog re-asserts in place (ConnMan regenerates
# resolv.conf); every apply arms a 180 s auto-revert unless confirmed.
# Details: docs/FINDINGS.md (F14g, F44).
#
# Subcommands:
#   start      resolver up, then apply + confirm (what layer 4 / boot hook call)
#   apply [--keep]   mount the override; auto-revert armed unless --keep
#   ensure     idempotent re-assert (watchdog)
#   confirm    disarm the auto-revert timer
#   revert     umount the override (resolver stays up)
#   stop       full teardown — also undoes Variant C via rollback-c.sh
#   status / log / test [domain ...]
#
# State keys (under $OYG_ROOT/state, written via lib/common.sh):
#   dns.applied=1          resolv.conf override in place
#   dns.upstream=<ip>      real upstream used as fallback nameserver
#
# Required:
#   python3 on PATH. All subcommands are idempotent (re-running is safe).
#   The auto-revert pid lives at $OYG_ROOT/dns-autorevert.pid.

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

DNS_BIND=${OYG_DNS_BIND:-$(cat "$OYG_ROOT/dns.bind" 2>/dev/null || echo 127.0.0.2)}
DNS_PORT=53
AUDIT_LOG="$OYG_ROOT/dns-audit.log"
HOSTS_FILE="$OYG_ROOT/hosts"
STATE_PID="$OYG_ROOT/dns.pid"
WATCHDOG_PID="$OYG_ROOT/watch-dns.pid"
TIMER_PID="$OYG_ROOT/dns-autorevert.pid"
RESOLV_TARGET=/etc/resolv.conf
RESOLV_SRC="$OYG_ROOT/resolv.conf.sinkhole"
AUTO_REVERT_SECS=${OYG_DNS_AUTO_REVERT:-180}

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

# NOTE: ensure_dirs() is provided by lib/common.sh (sourced above). Do NOT
# define a local stub here — an `ensure_dirs() { ensure_dirs; }` shadow
# recurses until the shell segfaults (observed: rc=139).

# _dns_upstream_valid <ip> — reject anything that would make the resolver
# forward to itself or into a black hole.
#
# WHY THIS EXISTS (observed outage, 2026-09-14): once ConnMan adopts our
# address as the service DNS (Variant A), connectionmanager's getStatus
# starts reporting dns1=127.0.0.2 — i.e. OUR OWN ADDRESS. The resolver then
# discovered its own address as its upstream, forwarded every query to
# itself, melted down, and every watchdog restart died with
# "bind(127.0.0.2:53) failed: EADDRNOTAVAIL". With connmand also pointing at
# 127.0.0.2 the device ended up with NO working DNS on either path.
_dns_upstream_valid() {
    cand=$1
    case "$cand" in
        ""|0.0.0.0|127.*|::1|::) return 1 ;;
    esac
    [ "$cand" = "$DNS_BIND" ] && return 1
    return 0
}

# Discover the UPSTREAM resolver (the fallback nameserver; NOT something we
# ever point connmand at). Mirrors dnssink.py's discovery: connectionmanager
# getStatus -> dns1, then dns2. Do NOT re-introduce "the first IPv4 in the
# blob" — that yields the netmask 255.255.255.0, which is not a resolver.
# Every candidate is passed through _dns_upstream_valid; if all sources fail
# we fall back to the last upstream that worked. Echoes "<ip> <source>".
discover_upstream() {
    ip=""
    src=""
    if have "$CONNMANCTL"; then
        ip=$("$CONNMANCTL" services 2>/dev/null \
            | sed -n 's/.*Nameservers=\(\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}\).*/\1/p' \
            | head -n 1)
        if _dns_upstream_valid "$ip"; then
            printf '%s %s\n' "$ip" "connmanctl"
            return 0
        fi
        if [ -n "$ip" ]; then
            warn_dns "upstream '$ip' from connmanctl is loopback/self — rejected (would forward to ourselves)"
        fi
    fi
    if have luna-send; then
        out=$(luna-send -n 1 -f \
            'luna://com.webos.service.connectionmanager/getStatus' \
            '{}' </dev/null 2>/dev/null) || out=""
        if [ -n "$out" ]; then
            # NB: getStatus contains SEVERAL IPv4-shaped values — netmask,
            # ipAddress, gateway, dns1, dns2 — and `netmask` comes first in
            # the JSON. Grabbing "the first IPv4 in the blob" therefore
            # yields 255.255.255.0, which is not a resolver: forwarding to
            # it would black-hole every lookup on the device. Only dns1 /
            # dns2 are resolvers; take those, in that order.
            for key in dns1 dns2; do
                cand=$(printf '%s' "$out" | tr ',' '\n' \
                    | grep "\"$key\"" \
                    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
                if _dns_upstream_valid "$cand"; then
                    printf '%s %s\n' "$cand" "luna-send($key)"
                    return 0
                fi
                if [ -n "$cand" ]; then
                    warn_dns "upstream '$cand' from luna-send/$key is loopback/self — rejected (would forward to ourselves)"
                fi
            done
        fi
    fi
    cand=$(ip route show default 2>/dev/null \
        | awk '/^default/ { for (i=1;i<=NF;i++) if ($i == "via") { print $(i+1); exit } }')
    if _dns_upstream_valid "$cand"; then
        printf '%s %s\n' "$cand" "gateway"
        return 0
    fi
    # Last resort: the last upstream that actually worked (remembered in
    # state by cmd_start). This is what saves us when every live source now
    # reports our OWN address — the exact situation that caused the outage.
    cand=$(state_get "dns.upstream" 2>/dev/null || true)
    if _dns_upstream_valid "$cand"; then
        printf '%s %s\n' "$cand" "cached(state)"
        return 0
    fi
    return 1
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
    # Probe a BLOCKED name — the answer (0.0.0.0/::) is generated locally
    # and is instant, unlike a forwarded name which waits on the upstream.
    out=$(nslookup -port=53 -timeout=1 es.nextlgsdp.com "$DNS_BIND" 2>&1) || true
    if printf '%s' "$out" | grep -Eq 'Address: '; then
        return 0
    fi
    return 1
}

# True resolv.conf path after following symlinks (/etc/resolv.conf ->
# /var/lib/misc/resolv.conf on this device; the bind mount lands on the
# resolved path and mountinfo records THAT path).
_resolv_real_target() {
    p=$RESOLV_TARGET
    if have readlink && r=$(readlink -f "$p" 2>/dev/null) && [ -n "$r" ]; then
        printf '%s' "$r"
        return 0
    fi
    n=0
    while [ -L "$p" ] && [ "$n" -lt 10 ]; do
        t=$(readlink "$p" 2>/dev/null) || break
        case "$t" in
            /*) p=$t ;;
            *)  p=$(dirname "$p")/$t ;;
        esac
        n=$((n + 1))
    done
    printf '%s' "$p"
}

# 0 if /etc/resolv.conf (or its resolved target) is currently a mount
# point. Field-based check (mountinfo field 5 / mounts field 2) — never a
# literal /dev/null grep.
_resolv_is_mounted() {
    [ -r /proc/self/mountinfo ] || [ -r /proc/mounts ] || return 1
    t1=$RESOLV_TARGET
    t2=$(_resolv_real_target)
    if [ -r /proc/self/mountinfo ]; then
        awk -v a="$t1" -v b="$t2" '{ if ($5 == a || $5 == b) m = 1 }
            END { exit (m ? 0 : 1) }' /proc/self/mountinfo && return 0
    fi
    if [ -r /proc/mounts ]; then
        awk -v a="$t1" -v b="$t2" '{ if ($2 == a || $2 == b) m = 1 }
            END { exit (m ? 0 : 1) }' /proc/mounts && return 0
    fi
    return 1
}

# 0 if the live resolv.conf still names our sinkhole first (ConnMan
# regenerates the file, which clobbers it — the watchdog re-asserts).
_resolv_content_ok() {
    grep -q '^nameserver[[:space:]]*127\.0\.0\.2' "$RESOLV_TARGET" 2>/dev/null
}

# Build the managed resolv.conf: our sinkhole FIRST, real upstream SECOND.
# Written IN PLACE (truncate + rewrite, never mv) so a live bind mount over
# it keeps showing the new content without re-mounting.
_write_resolv_src() {
    up=$1
    want="$RESOLV_SRC.want.$$"
    {
        printf '# own-your-glass DNS sinkhole (managed file; bind-mounted over /etc/resolv.conf)\n'
        printf '# primary: on-device sinkhole resolver. fallback: DHCP-learned upstream,\n'
        printf '# keeps DNS alive if the resolver dies.\n'
        printf 'nameserver %s\n' "$DNS_BIND"
        printf 'nameserver %s\n' "$up"
    } >"$want" 2>/dev/null || {
        rm -f "$want" 2>/dev/null || true
        return 1
    }
    if cmp -s "$want" "$RESOLV_SRC" 2>/dev/null; then
        rm -f "$want" 2>/dev/null || true
        return 0
    fi
    if cat "$want" >"$RESOLV_SRC" 2>/dev/null; then
        rm -f "$want" 2>/dev/null || true
        return 0
    fi
    rm -f "$want" 2>/dev/null || true
    return 1
}

# Probe the resolver DIRECTLY on 127.0.0.2 with a blocked name (answer must
# be 0.0.0.0 / ::) — proves it is live before resolv.conf points at it.
_probe_resolver_direct() {
    have nslookup || return 0
    out=$(nslookup -port=53 -timeout=2 es.nextlgsdp.com "$DNS_BIND" 2>&1) || true
    case "$out" in
        *0.0.0.0*|*::*) return 0 ;;
    esac
    return 1
}

# Verify THROUGH THE DEFAULT PATH (i.e. the resolver the box actually
# uses): blocked name -> 0.0.0.0/::, allowed name -> real IP.
_verify_default_path() {
    have nslookup || return 0
    bl=$(nslookup -timeout=2 es.nextlgsdp.com 2>&1) || true
    case "$bl" in
        *0.0.0.0*|*::*) : ;;
        *) return 1 ;;
    esac
    al=$(nslookup -timeout=2 www.youtube.com 2>&1) || true
    for a in $(printf '%s\n' "$al" | grep 'Address:' |
        sed 's/.*Address:[[:space:]]*//' | cut -d'#' -f1 | tr -d ' '); do
        case "$a" in
            127.*|0.0.0.0|::|"") continue ;;
            *.*.*.*) return 0 ;;
        esac
    done
    return 1
}

# Arm the auto-revert timer: a detached job that unmounts the override
# after ~180 s unless disarmed. If anything goes wrong and the shell dies,
# the TV heals itself.
_arm_autorevert() {
    _cancel_autorevert
    nohup sh "$0" _autorevert "$AUTO_REVERT_SECS" \
        </dev/null >>"$OYG_ROOT/dns.log" 2>&1 &
    tp=$!
    printf '%s\n' "$tp" >"$TIMER_PID" 2>/dev/null || true
    ok_dns "auto-revert armed: override auto-unmounts in ${AUTO_REVERT_SECS}s unless confirmed (pid $tp)"
}

_cancel_autorevert() {
    [ -r "$TIMER_PID" ] || return 0
    tp=$(cat "$TIMER_PID" 2>/dev/null || true)
    rm -f "$TIMER_PID" 2>/dev/null || true
    if [ -n "${tp:-}" ] && [ "$tp" != "$$" ] && kill -0 "$tp" 2>/dev/null; then
        kill -TERM "$tp" 2>/dev/null || true
        ok_dns "auto-revert disarmed (pid $tp)"
    fi
    return 0
}

_autorevert() {
    secs=${1:-$AUTO_REVERT_SECS}
    printf '%s\n' "$$" >"$TIMER_PID" 2>/dev/null || true
    sleep "$secs" 2>/dev/null || sleep 180
    rm -f "$TIMER_PID" 2>/dev/null || true
    if [ "$(state_get dns.applied 2>/dev/null)" = "1" ]; then
        warn_dns "auto-revert timer fired: undoing the resolv.conf override"
        cmd_revert
    else
        log_dns "auto-revert timer fired: no override applied, nothing to undo"
    fi
    exit 0
}

_spawn_watchdog() {
    if [ -r "$WATCHDOG" ] && [ ! -r "$WATCHDOG_PID" ]; then
        nohup sh "$WATCHDOG" >>"$OYG_ROOT/dns.log" 2>&1 &
        # nohup returns; let the daemon write its own pid file.
        sleep 0.3
        ok_dns "watchdog spawned"
    fi
}

##############################################################################
# Subcommands
##############################################################################

usage() {
    cat <<EOF
dns.sh — on-device DNS sinkhole operator (resolv.conf bind-mount route)

Usage:
  scripts/dns.sh start              # resolver up + apply + confirm (permanent)
  scripts/dns.sh apply [--keep]     # mount the resolv.conf override; auto-revert
                                    # armed unless --keep (or run: confirm)
  scripts/dns.sh ensure             # idempotent re-assert (watchdog)
  scripts/dns.sh confirm            # disarm the auto-revert timer
  scripts/dns.sh revert             # undo the override (umount), resolver stays up
  scripts/dns.sh stop               # full teardown (watchdog, override, resolver)
  scripts/dns.sh status             # print what is live
  scripts/dns.sh log                # tail the audit log
  scripts/dns.sh test [domain ...]  # live probes against 127.0.0.2

State keys managed under \$OYG_ROOT/state:
  dns.applied        1 if the resolv.conf override is in place
  dns.upstream       real upstream used as the fallback nameserver

Auto-revert: every apply arms a background job that unmounts the override
after ~180 s (OYG_DNS_AUTO_REVERT) unless disarmed by 'confirm' / start.
Never signals, reloads or restarts connmand (see the post-mortem above).
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
            # Remember the last upstream that worked. If ConnMan ever adopts
            # our own address as the service DNS, every live source starts
            # reporting 127.0.0.2 — this cached value is then the only thing
            # that still resolves. (See _dns_upstream_valid.)
            state_put "dns.upstream" "$upstream"
            state_put "dns.upstream.src" "$up_src"
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

        # Prove it answers BEFORE pointing resolv.conf at it.
        if ! _probe_resolver_direct; then
            err_dns "resolver up but NOT answering blocked queries on $DNS_BIND:$DNS_PORT — aborting before touching resolv.conf"
            kill -TERM "$pid" 2>/dev/null || true
            rm -f "$STATE_PID" 2>/dev/null || true
            return 1
        fi
        ok_dns "resolver verified answering on $DNS_BIND:$DNS_PORT (blocked -> 0.0.0.0/::)"
    fi

    cmd_apply --keep
}

cmd_apply() {
    keep=0
    case "${1:-}" in
        --keep) keep=1 ;;
    esac
    require_root

    # The resolver MUST be live before resolv.conf points at it.
    if ! resolver_alive; then
        err_dns "resolver is not answering on $DNS_BIND:$DNS_PORT — refusing to point resolv.conf at it"
        err_dns "  run: scripts/dns.sh start"
        return 1
    fi

    up=$(state_get dns.upstream 2>/dev/null || true)
    if [ -z "$up" ]; then
        if up_pair=$(discover_upstream) && [ -n "${up_pair%% *}" ]; then
            up=${up_pair%% *}
        else
            err_dns "cannot discover the real upstream — not applying the override"
            return 2
        fi
    fi
    state_put dns.upstream "$up"

    ensure_dirs
    if ! _write_resolv_src "$up"; then
        err_dns "cannot write $RESOLV_SRC"
        return 1
    fi

    if _resolv_is_mounted; then
        ok_dns "resolv.conf override already mounted"
        if ! _resolv_content_ok; then
            warn_dns "override mounted but content clobbered (ConnMan regenerated resolv.conf) — re-writing in place"
            _write_resolv_src "$up"
            if ! _resolv_content_ok; then
                warn_dns "content still wrong after re-write — unmounting and mounting fresh"
                umount "$RESOLV_TARGET" 2>/dev/null \
                    || umount "$(_resolv_real_target)" 2>/dev/null \
                    || true
            fi
        fi
    fi

    if ! _resolv_is_mounted; then
        # Arm the safety net FIRST, then mount.
        _arm_autorevert
        if mount --bind "$RESOLV_SRC" "$RESOLV_TARGET" 2>/dev/null; then
            ok_dns "bind-mounted $RESOLV_SRC over $RESOLV_TARGET"
        else
            err_dns "mount --bind failed — the TV keeps ConnMan's own resolv.conf; auto-revert is running"
            return 1
        fi
    fi

    state_put dns.applied "1"

    if ! _verify_default_path; then
        err_dns "default-path DNS check FAILED after mounting — reverting immediately"
        cmd_revert
        return 1
    fi
    ok_dns "default-path DNS verified (blocked -> 0.0.0.0/::, allowed -> real IP)"

    if [ "$keep" = "1" ]; then
        _cancel_autorevert
        ok_dns "override confirmed (auto-revert disarmed)"
    else
        warn_dns "override is TENTATIVE — auto-revert will undo it in ${AUTO_REVERT_SECS}s unless you run: scripts/dns.sh confirm"
    fi

    _spawn_watchdog
    return 0
}

cmd_ensure() {
    require_root
    [ "$(state_get dns.applied 2>/dev/null)" = "1" ] || return 0
    up=$(state_get dns.upstream 2>/dev/null || true)
    if [ -z "$up" ]; then
        if up_pair=$(discover_upstream) && [ -n "${up_pair%% *}" ]; then
            up=${up_pair%% *}
            state_put dns.upstream "$up"
        else
            warn_dns "cannot re-assert the override (no upstream discovered)"
            return 1
        fi
    fi
    ensure_dirs
    _write_resolv_src "$up" || return 1
    if _resolv_is_mounted; then
        _resolv_content_ok && return 0
        # Mounted but clobbered — rewrite in place (same inode, no re-mount).
        _write_resolv_src "$up"
        _resolv_content_ok && return 0
        # A stale/foreign mount: unmount and mount fresh.
        warn_dns "resolv.conf mount present but content wrong — unmounting and re-mounting"
        umount "$RESOLV_TARGET" 2>/dev/null \
            || umount "$(_resolv_real_target)" 2>/dev/null \
            || true
    fi
    _write_resolv_src "$up" || return 1
    if ! _resolv_is_mounted; then
        if mount --bind "$RESOLV_SRC" "$RESOLV_TARGET" 2>/dev/null; then
            ok_dns "re-asserted: bind-mounted $RESOLV_SRC over $RESOLV_TARGET"
        else
            warn_dns "re-mount failed — resolv.conf is ConnMan's own until the next ensure"
            return 1
        fi
    fi
    return 0
}

cmd_confirm() {
    require_root
    _cancel_autorevert
    ok_dns "override confirmed (auto-revert disarmed)"
}

cmd_revert() {
    require_root
    _cancel_autorevert
    rv=0
    if _resolv_is_mounted; then
        if umount "$RESOLV_TARGET" 2>/dev/null \
            || umount "$(_resolv_real_target)" 2>/dev/null; then
            ok_dns "unmounted the resolv.conf override — TV back on ConnMan's own resolv.conf"
        else
            err_dns "umount failed — override still in place"
            rv=1
        fi
    else
        ok_dns "no resolv.conf override mounted"
    fi
    state_drop dns.applied
    state_drop dns.upstream
    return $rv
}

cmd_stop() {
    require_root

    # Variant C is active? Undo it first. With connmand proxy-less and the
    # sink on 127.0.0.1, a bare stop would leave resolv.conf pointing at a
    # dead 127.0.0.1 — and connmand would NOT resume its own proxy, because
    # it never restarts itself here (see the post-mortem). rollback-c.sh
    # restores the stock launcher and restarts connmand; the sink it would
    # restart is not wanted — we are stopping everything — hence the knob.
    if [ "$(cat "$OYG_ROOT/dns.bind" 2>/dev/null)" = "127.0.0.1" ] \
        && awk '$5=="/etc/systemd/system/scripts/connman.sh"{f=1} END{exit !f}' /proc/self/mountinfo; then
        if [ -x "$OYG_ROOT/rollback-c.sh" ]; then
            ROLLBACK_NO_SINK=1 sh "$OYG_ROOT/rollback-c.sh" || true
            ok_dns "Variant C undone (stock connman launcher restored)"
        else
            warn_dns "dns.bind says C is active but rollback-c.sh is missing — connmand stays proxy-less until reboot"
        fi
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

    _cancel_autorevert
    cmd_revert || true

    # Stop the resolver.
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

    state_drop dns.applied
    state_drop dns.upstream
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

    if [ "$(state_get dns.applied 2>/dev/null)" = "1" ]; then
        if _resolv_is_mounted; then
            if _resolv_content_ok; then
                print_status OK "resolv.conf override mounted + carries nameserver $DNS_BIND first ($(_resolv_real_target))"
            else
                print_status PARTIAL "resolv.conf override mounted but content clobbered (watchdog should re-assert)"
            fi
        else
            print_status FAIL "dns.applied=1 but no resolv.conf override mount (re-apply: scripts/dns.sh start)"
        fi
        up=$(state_get dns.upstream 2>/dev/null || true)
        if [ -n "$up" ]; then
            print_status OK "upstream fallback=$up (also used by the resolver)"
        fi
        if [ -r "$TIMER_PID" ]; then
            tp=$(cat "$TIMER_PID" 2>/dev/null || true)
            print_status PARTIAL "auto-revert armed (pid ${tp:-?}) — run 'scripts/dns.sh confirm' to make the override permanent"
        fi
    else
        print_status N/A "no resolv.conf override applied"
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

main() {
    if ! oyg_guard_connman_route "$OYG_HERE/dns.sh" "$OYG_HERE/watch-dns.sh"; then
        err_dns "ConnMan signal/reload pattern detected — refusing to run. See the post-mortem in this file."
        exit 1
    fi
    sub=${1:-help}
    [ $# -gt 0 ] && shift || true
    case "$sub" in
        start)      cmd_start ;;
        apply)      cmd_apply "$@" ;;
        ensure)     cmd_ensure ;;
        confirm)    cmd_confirm ;;
        revert)     cmd_revert ;;
        stop)       cmd_stop ;;
        status)     cmd_status ;;
        log)        cmd_log ;;
        test)       cmd_test "$@" ;;
        _autorevert) _autorevert "${1:-$AUTO_REVERT_SECS}" ;;
        -h|--help|help) usage ;;
        *) err_dns "unknown subcommand: $sub"; usage; exit 64 ;;
    esac
}

main "$@"