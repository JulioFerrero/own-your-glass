#!/bin/sh
# recover-network.sh — the panic button.
#
# Restores a WORKING NETWORK from the TV itself, with no SSH and no network
# needed to reach it. This is the counterpart to the risky "Variant C"
# operation: if taking /etc/resolv.conf or ConnMan's DNS breaks DNS (or the
# link), this puts the box back to stock networking.
#
# WHY THIS EXISTS
# ---------------
# Every "Variant C" attempt needs a way back that does not depend on the
# network being up. The TV's own UI + org.webosbrew.hbchannel.service/exec
# (root, over the LOCAL bus) is that way back — see app/index.html. This
# script is what that button runs.
#
# WHAT IT DOES, IN ORDER (least destructive first)
#   1. Stop the DNS sinkhole + its watchdog (dns.sh stop) — unmounts the
#      /etc/resolv.conf override so ConnMan's own resolv.conf is live again.
#      If dns.sh is not installed, skip.
#   2. Clear a manual ConnMan nameserver override, so the DHCP-provided
#      resolvers are used again. Uses ConnMan's own API (connmanctl config);
#      it never signals, reloads or restarts connmand.
#   3. If wlan0 still has NO IPv4 address, install a static fallback address
#      and default route so we keep a shell. The address is deliberately
#      outside the router's DHCP pool (see STATIC_IP below).
#   4. Print exactly what it did, so the UI can show it.
#
# NEVER signals, reloads or restarts connmand — see the post-mortem in
# scripts/dns.sh. oyg_guard_connman_route enforces that.

set -u

OYG_HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OYG_ROOT=${OYG_ROOT:-$(CDPATH= cd -- "$OYG_HERE/.." && pwd)}
if [ -r "$OYG_ROOT/lib/common.sh" ]; then
    . "$OYG_ROOT/lib/common.sh"
fi

WIFI_IF=${OYG_WIFI_IF:-wlan0}
STATIC_IP=${OYG_STATIC_IP:-192.168.1.240}
STATIC_PREFIX=${OYG_STATIC_PREFIX:-24}
GW=$(ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')

say() { printf '%s\n' "$*"; }

echo "== recover-network =="

# --- 1. drop the DNS sinkhole + override ------------------------------------
if [ -x "$OYG_HERE/dns.sh" ]; then
    if sh "$OYG_HERE/dns.sh" stop 2>&1 | sed 's/^/   /'; then
        say "OK   sinkhole stopped; /etc/resolv.conf override removed"
    else
        say "WARN dns.sh stop reported a problem (continuing)"
    fi
    # Belt and braces: if the dns.sh unmount path missed, unmount by hand.
    for m in $(awk '$5 ~ /resolv\.conf\.sinkhole/{print $5}' /proc/self/mountinfo 2>/dev/null); do
        umount "$m" 2>/dev/null && say "OK   unmounted $m"
    done
else
    say "N/A  dns.sh not present — nothing to stop"
fi

# --- 2. let ConnMan use the DHCP resolvers again ----------------------------
if command -v connmanctl >/dev/null 2>&1; then
    svc=$(connmanctl services 2>/dev/null | awk '/^\*/{print $NF}' | head -1)
    if [ -n "${svc:-}" ]; then
        # Only touch it if a manual override is actually present.
        if grep -q '^Nameservers=' "/var/lib/connman/$svc/settings" 2>/dev/null; then
            # DHCP-learned resolvers come back on the next reconnect; setting
            # them explicitly here is what un-breaks a wedged resolver list.
            if connmanctl config "$svc" --nameservers 80.58.61.254 80.58.61.250 >/dev/null 2>&1; then
                say "OK   ConnMan nameserver override replaced with the ISP resolvers"
            else
                say "WARN could not rewrite ConnMan nameservers (continuing)"
            fi
        else
            say "OK   no ConnMan nameserver override present"
        fi
    fi
fi

# --- 3. last-resort static address ------------------------------------------
v4=$(ip -4 addr show "$WIFI_IF" 2>/dev/null | awk '/inet /{print $2}' | head -1)
if [ -n "$v4" ]; then
    say "OK   $WIFI_IF already has $v4 — no static fallback needed"
else
    say "WARN $WIFI_IF has no IPv4 — installing static fallback $STATIC_IP/$STATIC_PREFIX"
    ip addr add "$STATIC_IP/$STATIC_PREFIX" dev "$WIFI_IF" 2>/dev/null \
        && say "OK   added $STATIC_IP/$STATIC_PREFIX to $WIFI_IF" \
        || say "ERR  could not add the static address"
    if [ -n "${GW:-}" ]; then
        ip route add default via "$GW" dev "$WIFI_IF" 2>/dev/null \
            && say "OK   default route via $GW" \
            || say "N/A  default route already present or could not be added"
    else
        say "WARN no gateway known — could not add a default route"
    fi
fi

# --- 4. report --------------------------------------------------------------
say ""
say "== final state =="
say "   interfaces: $(ip -4 addr show "$WIFI_IF" 2>/dev/null | awk '/inet /{printf "%s ", $2}')"
resolv=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')
say "   resolv.conf: ${resolv:-<none>}"
if command -v nslookup >/dev/null 2>&1; then
    ans=$(nslookup github.com 2>/dev/null | awk '/^Address/ && !/#53$/{print $2}' | tail -1)
    say "   test lookup (github.com): ${ans:-FAILED}"
else
    say "   test lookup: skipped (no nslookup)"
fi
say ""
say "If the TV UI is still reachable, you can now re-run 'DNS sink ON'."
