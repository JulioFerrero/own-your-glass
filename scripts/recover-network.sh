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
#   2. Clear a loopback ConnMan nameserver override (the old ConnMan route
#      wrote one), so the DHCP-provided resolvers are used again. A DNS the
#      owner set by hand (Pi-hole, 1.1.1.1, ...) is left alone. Uses
#      ConnMan's own API (connmanctl config); it never signals, reloads or
#      restarts connmand.
#   3. If the TV has no default route and wlan0 has NO IPv4 address, put
#      back the last address DHCP gave it (or OYG_STATIC_IP) so we keep a
#      shell. On Ethernet, or anything else that still routes, it does
#      nothing.
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
STATIC_IP=${OYG_STATIC_IP:-}
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
if type connmanctl >/dev/null 2>&1; then
    svc=$(connmanctl services 2>/dev/null | awk '/^\*/{print $NF}' | head -n 1)
    if [ -n "${svc:-}" ]; then
        # Only a loopback override is ours to clear; an empty list hands the
        # service back to the DHCP-provided resolvers.
        if grep -q '^Nameservers=127\.' "/var/lib/connman/$svc/settings" 2>/dev/null; then
            if connmanctl config "$svc" --nameservers >/dev/null 2>&1; then
                say "OK   loopback ConnMan nameserver override cleared (DHCP resolvers)"
            else
                say "WARN could not clear the ConnMan nameserver override (continuing)"
            fi
        elif grep -q '^Nameservers=' "/var/lib/connman/$svc/settings" 2>/dev/null; then
            say "OK   ConnMan nameservers set by hand — left alone"
        else
            say "OK   no ConnMan nameserver override present"
        fi
        [ -n "$STATIC_IP" ] || STATIC_IP=$(sed -n 's/^IPv4\.DHCP\.LastAddress=//p' \
            "/var/lib/connman/$svc/settings" 2>/dev/null | head -n 1)
    fi
fi

# --- 3. last-resort static address ------------------------------------------
v4=$(ip -4 addr show "$WIFI_IF" 2>/dev/null | awk '/inet /{print $2}' | head -n 1)
if [ -n "$v4" ]; then
    say "OK   $WIFI_IF already has $v4 — no static fallback needed"
elif [ -n "${GW:-}" ]; then
    say "OK   default route via $GW — no static fallback needed"
elif [ -z "$STATIC_IP" ]; then
    say "WARN $WIFI_IF has no IPv4 and no earlier DHCP address is known — set OYG_STATIC_IP for a fallback"
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
if type nslookup >/dev/null 2>&1; then
    ans=$(nslookup github.com 2>/dev/null | awk '/^Address/ && !/#53$/{print $2}' | tail -n 1)
    say "   test lookup (github.com): ${ans:-FAILED}"
else
    say "   test lookup: skipped (no nslookup)"
fi
say ""
say "If the TV UI is still reachable, you can now re-run 'DNS sink ON'."
