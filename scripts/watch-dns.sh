#!/bin/sh
# watch-dns.sh — watchdog for the on-device DNS sinkhole resolver.
#
# Every loop (default: every 15 s):
#   1. if dns.applied=1, re-assert the resolv.conf override — ConnMan
#      regenerates /etc/resolv.conf, which would otherwise clobber our
#      nameservers. `dns.sh ensure` rewrites the managed file in place
#      and re-mounts only if the bind actually vanished (idempotent,
#      never stacks mounts).
#   2. probe the resolver; if it is genuinely dead, restart it (up to N tries).
#   3. if it will not come back, REVERT the override (umount) so the TV
#      falls back to ConnMan's own resolv.conf — never left without DNS.
#
# NEVER signals, reloads or restarts connmand. oyg_guard_connman_route
# refuses to start if any forbidden pattern sneaks back into these files
# (see the post-mortem in scripts/dns.sh).
#
# WHY THE PROBE WAS REWRITTEN (observed, 2026-09-14)
# ---------------------------------------------------
# The first version was:
#     out=$(nslookup -port=53 -timeout=1 es.nextlgsdp.com "$DNS_BIND")
#     printf '%s' "$out" | grep -Eq 'Address: ' && return 0
# and it KILLED A HEALTHY RESOLVER 16 s after a good start, then failed to
# bring it back (bind 127.0.0.2:53 EADDRNOTAVAIL), leaving the TV with no
# working DNS. Three flaws:
#   1. it depended on busybox nslookup's flag syntax and on parsing text;
#   2. it required a particular ANSWER — but a blocked name legitimately
#      answers 0.0.0.0/::, so "no A record" is a HEALTHY resolver;
#   3. restart_resolver() killed whatever PID was in dns.pid without
#      checking it was actually ours, and started a replacement without
#      waiting for the old process to release the port.
# The probe now asks the only question that matters — "did we get a
# well-formed DNS reply?" — with a raw UDP query, and requires TWO
# consecutive failures before touching anything (debounce).
#
# Started by install.sh's init.d/oyg boot hook (state-gated on
# dns.applied=1) or by scripts/dns.sh apply. Writes its own pid under
# $OYG_ROOT/watch-dns.pid so `dns.sh stop` can terminate it.
#
# Exit: never. Caller kills it with TERM.

set -u

OYG_HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$OYG_HERE/../lib/common.sh"

PY=${PY:-python3}
PROBE_INTERVAL=${OYG_WATCHDNS_INTERVAL:-15}
RESTART_TRIES=${OYG_WATCHDNS_TRIES:-3}
RESTART_GAP=${OYG_WATCHDNS_GAP:-2}
FAILS_BEFORE_ACTION=${OYG_WATCHDNS_FAILS:-2}
STATE_PID="$OYG_ROOT/dns.pid"
WATCHDOG_PID="$OYG_ROOT/watch-dns.pid"
DNS_BIND=127.0.0.2
DNS_PORT=53
PROBE_NAME=es.nextlgsdp.com

printf '%s\n' "$$" >"$WATCHDOG_PID"

log_wd()  { log "watch-dns: $*"; }
ok_wd()   { ok "watch-dns: $*"; }
warn_wd() { warn "watch-dns: $*"; }
err_wd()  { err "watch-dns: $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# probe_resolver — exit 0 iff a well-formed DNS reply came back from the
# sink. ANY reply counts: a blocked name answering 0.0.0.0/:: is healthy.
# Falls back to "alive" when python3 is missing, so we never kill a
# resolver we cannot actually test.
probe_resolver() {
    have "$PY" || return 0
    "$PY" - "$DNS_BIND" "$DNS_PORT" "$PROBE_NAME" <<'PYEOF' 2>/dev/null
import socket, struct, sys
addr, port, name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
tid = b"\xab\xcd"
hdr = tid + b"\x01\x00" + struct.pack(">HHHH", 1, 0, 0, 0)
qn = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00"
pkt = hdr + qn + struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2.0)
try:
    s.sendto(pkt, (addr, port))
    data, _ = s.recvfrom(512)
except Exception:
    sys.exit(1)
finally:
    try:
        s.close()
    except Exception:
        pass
sys.exit(0 if len(data) >= 12 and data[0:2] == tid else 1)
PYEOF
}

# resolver_pid_ok — the pid in dns.pid is alive AND is really our resolver.
# Without the cmdline check we can kill a bystander that reused the pid.
resolver_pid_ok() {
    pid=$(cat "$STATE_PID" 2>/dev/null || true)
    [ -n "${pid:-}" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q 'dnssink' || return 1
    return 0
}

restart_resolver() {
    if resolver_pid_ok; then
        pid=$(cat "$STATE_PID" 2>/dev/null || true)
        warn_wd "stopping unresponsive resolver pid $pid"
        kill -TERM "$pid" 2>/dev/null || true
        # Wait for it to actually exit — starting a replacement while the
        # old socket is still held is what produced the EADDRNOTAVAIL loop.
        n=0
        while [ "$n" -lt 20 ] && kill -0 "$pid" 2>/dev/null; do
            sleep 0.2
            n=$((n + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
            sleep 0.5
        fi
    fi
    "$OYG_HERE/dns.sh" start >/dev/null 2>&1 || true
    sleep 1
    probe_resolver
}

main() {
    if ! oyg_guard_connman_route "$OYG_HERE/dns.sh" "$OYG_HERE/watch-dns.sh"; then
        err_wd "ConnMan signal/reload pattern detected — refusing to run"
        rm -f "$WATCHDOG_PID" 2>/dev/null || true
        exit 1
    fi
    log_wd "starting (interval=${PROBE_INTERVAL}s tries=${RESTART_TRIES} fails-before-action=${FAILS_BEFORE_ACTION})"
    trap 'rm -f "$WATCHDOG_PID" 2>/dev/null || true; exit 0' TERM INT

    fails=0
    while :; do
        sleep "$PROBE_INTERVAL" 2>/dev/null || sleep 1
        [ "$(state_get dns.applied 2>/dev/null)" = "1" ] || { fails=0; continue; }

        # Periodic re-apply: ConnMan regenerates resolv.conf and would
        # otherwise clobber our nameservers. Idempotent, never stacks.
        "$OYG_HERE/dns.sh" ensure >/dev/null 2>&1 \
            || warn_wd "re-assert of the resolv.conf override failed"

        if probe_resolver; then
            fails=0
            continue
        fi

        # Debounce: one missed probe under load is not a death.
        fails=$((fails + 1))
        if [ "$fails" -lt "$FAILS_BEFORE_ACTION" ]; then
            warn_wd "probe missed ($fails/$FAILS_BEFORE_ACTION) — not acting yet"
            continue
        fi

        warn_wd "resolver not answering after $fails probes — attempting restart"
        ok=1
        i=1
        while [ "$i" -le "$RESTART_TRIES" ]; do
            if restart_resolver; then
                ok=0
                ok_wd "restart succeeded on try $i"
                break
            fi
            i=$((i + 1))
            sleep "$RESTART_GAP" 2>/dev/null || sleep 1
        done
        if [ "$ok" != "0" ]; then
            err_wd "resolver did not come back after $RESTART_TRIES tries — reverting the resolv.conf override"
            "$OYG_HERE/dns.sh" revert >/dev/null 2>&1 \
                || err_wd "revert failed; investigate manually"
        fi
        fails=0
    done
}

main "$@"
