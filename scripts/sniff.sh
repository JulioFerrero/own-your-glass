#!/bin/sh
# sniff.sh — on-device packet sniffer (POSIX sh wrapper around sniff.py).
#
# Runs ON the TV (where AF_PACKET + root is available). From the operator's
# machine it is driven over ssh:
#
#   ssh lgtv 'sh /var/lib/own-your-glass/sniff.sh --seconds 30'
#   ssh lgtv 'sh /var/lib/own-your-glass/sniff.sh --pcap /tmp/tv.pcap --seconds 60'
#   scp lgtv:/tmp/tv.pcap .   # then open in Wireshark
#
# Why a wrapper at all: the Python sniffer uses socket.AF_PACKET + ETH_P_ALL
# from the stdlib. tcpdump / libpcap / tcpdump's setcap binary are NOT
# available on this device, and netfilter is absent, but AF_PACKET works on
# any kernel that supports it. We run as root over ssh (default for this TV).
#
# Usage:
#   scripts/sniff.sh [options]
#
# Options (forwarded to sniff.py; see scripts/sniff.py --help for full list):
#   -i IFACE          capture interface (default: auto-detect from default route)
#   -d, --seconds N   stop after N seconds (default: until Ctrl-C)
#   --pcap FILE       write libpcap-format capture to FILE (open in Wireshark)
#       --exclude-port PORT    repeatable; default-excludes TCP 22 (ssh) + 9998
#       --dns --sni --tcp --all    filter categories (default: DNS + SNI + SYN + sinkhole)
#       -q, --quiet    suppress the banner
#
# Exit codes:
#   0  ok (capture ran to completion or was interrupted)
#   1  missing tool (python3) or bad args
#   2  interface not found / not up
#   3  not root (raw packet capture requires CAP_NET_RAW on Linux)

set -eu

OYG_HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '[sniff] %s\n' "$*"; }
err()  { printf '[sniff] ERR  %s\n' "$*" >&2; }

# Auto-detect the interface that carries the default route. Mirrors the
# pattern used in modules/network.sh (`ip route show default`).
detect_iface() {
    ip route show default 2>/dev/null \
        | awk '/^default/ { for (i=1;i<=NF;i++) if ($i == "dev") { print $(i+1); exit } }'
}

# Parse -i early so we can validate the interface before exec. Anything
# else is forwarded verbatim.
IFACE=""
args=""
while [ $# -gt 0 ]; do
    case "$1" in
        -i)
            IFACE=${2:-}
            [ -n "$IFACE" ] || { err "-i requires an interface name"; exit 1; }
            args="$args -i $IFACE"
            shift 2 ;;
        -i=*)
            IFACE=${1#-i=}
            args="$args -i $IFACE"
            shift ;;
        --help|-h)
            exec python3 "$OYG_HERE/sniff.py" --help ;;
        *)
            args="$args $1"
            shift ;;
    esac
done

have python3 || { err "python3 not found in PATH"; exit 1; }

if [ -z "$IFACE" ]; then
    IFACE=$(detect_iface)
    if [ -z "$IFACE" ]; then
        err "could not auto-detect interface (no default route?)"
        err "  pass one explicitly with -i IFACE (e.g. -i wlan0)"
        exit 2
    fi
    log "auto-detected interface: $IFACE"
    args="-i $IFACE $args"
fi

# Validate the interface exists and is up. We do not refuse if it is
# DOWN (the TV's wlan0 can flicker) — the Python sniffer will surface a
# clear error from the bind() call instead.
if ! ip -o link show dev "$IFACE" >/dev/null 2>&1; then
    err "interface '$IFACE' does not exist"
    err "  available: $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | tr '\n' ' ')"
    exit 2
fi

# Root is required for AF_PACKET. ssh to this TV defaults to root, but if
# the operator is running it under their own account the CAP_NET_RAW check
# is the load-bearing one (setcap can also grant it). We refuse on a
# uid-not-zero without a CAP_NET_RAW fallback to keep the failure mode
# obvious; the bind() would just EACCES otherwise.
if [ "$(id -u 2>/dev/null || echo 0)" -ne 0 ]; then
    err "AF_PACKET capture requires root (uid=$(id -u))"
    err "  this TV's SSH user is 'root' by default — re-run as root"
    exit 3
fi

# shellcheck disable=SC2086
exec python3 "$OYG_HERE/sniff.py" $args