#!/bin/sh
# Variant C: stop ConnMan's DNS proxy (-r) so the sink can own 127.0.0.1:53.
# Runs detached; every safety net armed inside; cancels rollback on success.
# The network it protects (service, interface, address, gateway, the sink's
# upstream) is read from the TV before connmand is touched; nothing is
# hardcoded. Needs the DNS sink running first (layer 4, OYG_DNS_RESOLVER=1).
#
#   sh go-c.sh --check   print what was found and what would happen
#   sh go-c.sh           do it (run detached: nohup sh go-c.sh </dev/null &)
R=${OYG_ROOT:-/var/lib/own-your-glass}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOG=$R/go-c.log
LAUNCHER=/etc/systemd/system/scripts/connman.sh
PATCHED=$R/connman.sh.patched
ROLLBACK=$HERE/rollback-c.sh
ROLLBACK_SECS=660
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

logit() {
    if [ "$CHECK" = "1" ]; then
        printf '%s\n' "$*"
    else
        printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"
    fi
}
die() { logit "ABORT: $*"; exit 1; }

launcher_mounted() {
    awk -v t="$LAUNCHER" '$5 == t { f = 1 } END { exit !f }' /proc/self/mountinfo
}

# connmand_on_53 <pid> — true while that process holds UDP 127.0.0.1:53
# (0100007F:0035 in /proc/net/udp; field 10 is the socket inode).
connmand_on_53() {
    for i in $(awk '$2 == "0100007F:0035" { print $10 }' /proc/net/udp); do
        ls -l "/proc/$1/fd" 2>/dev/null | grep -q "socket:\[$i\]" && return 0
    done
    return 1
}

[ "$CHECK" = "1" ] || { : > "$LOG"; rm -f "$R/go-c.done"; }
logit "=== Variant C $([ "$CHECK" = "1" ] && echo check || echo starting) ==="

# 0. read the network as it is now, while it works
IFACE=$(ip route show default 2>/dev/null | awk '/^default/ { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
GW=$(ip route show default 2>/dev/null | awk '/^default/ { for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }')
[ -n "$IFACE" ] && [ -n "$GW" ] || die "no default route — the TV is not online"
ADDR=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / { print $2; exit }')
[ -n "$ADDR" ] || die "$IFACE has no IPv4 address"
SVC=$(connmanctl services 2>/dev/null | awk '/^\*/ { print $NF; exit }')
[ -n "$SVC" ] || die "connmanctl shows no connected service"
UP=$(awk -F= '$1 == "dns.upstream" { sub(/^[^=]*=/, ""); print; exit }' "$R/state" 2>/dev/null)
[ -n "$UP" ] || die "no dns.upstream in $R/state — start the DNS sink first (oyg harden with OYG_DNS_RESOLVER=1)"
BLOCKED=$(awk '$1 == "0.0.0.0" && $2 != "0.0.0.0" && $2 ~ /\./ { print $2; exit }' "$R/hosts" 2>/dev/null)
[ -n "$BLOCKED" ] || die "no blocked name in $R/hosts to verify with"
[ -r "$ROLLBACK" ] || die "$ROLLBACK missing"
[ -f "$LAUNCHER" ] || die "$LAUNCHER missing — this firmware starts connmand another way"
logit "network: $IFACE $ADDR via $GW, service $SVC, sink upstream $UP"

# 1. the patched launcher: the stock one with -r on its connmand exec line.
# While the patch is mounted the stock file is hidden, so keep the copy.
if launcher_mounted; then
    [ -r "$PATCHED" ] || die "$LAUNCHER is bind-mounted but $PATCHED is missing"
    logit "launcher: already patched and mounted"
else
    n=$(grep -c '^[[:space:]]*exec[[:space:]].*/connmand[[:space:]]' "$LAUNCHER")
    [ "$n" = "1" ] || die "expected one 'exec .../connmand' line in $LAUNCHER, found $n"
    tmp=$R/connman.sh.patched.new
    awk '/^[[:space:]]*exec[[:space:]].*\/connmand[[:space:]]/ && !/[[:space:]](-r|--nodnsproxy)([[:space:]]|$)/ {
             sub(/\/connmand[[:space:]]/, "/connmand -r ")
         } { print }' "$LAUNCHER" > "$tmp" || die "cannot write $tmp"
    changed=$(diff -U0 "$LAUNCHER" "$tmp" | grep -v '^+++ ' | grep -c '^+')
    [ "$changed" -le 1 ] || { rm -f "$tmp"; die "patch changed $changed lines, expected 1"; }
    chmod 0755 "$tmp"
    if [ "$CHECK" = "1" ]; then
        logit "launcher: would use: $(grep '^[[:space:]]*exec[[:space:]].*/connmand' "$tmp" | sed 's/^[[:space:]]*//')"
        rm -f "$tmp"
    else
        mv "$tmp" "$PATCHED" || die "cannot write $PATCHED"
        logit "launcher: patched copy at $PATCHED"
    fi
fi
logit "verify names: blocked $BLOCKED, allowed github.com"

if [ "$CHECK" = "1" ]; then
    logit "would: arm a ${ROLLBACK_SECS}s rollback, mount the patched launcher, restart connman,"
    logit "       wait for the new connmand to leave 127.0.0.1:53, move the sink there, and verify"
    exit 0
fi
logit "connmand pid before: $(pidof connmand)"

# 2. rollback timer (fires unless go-c.done appears)
pkill -f 'rollback-c.sh' 2>/dev/null
( sleep $ROLLBACK_SECS; sh "$ROLLBACK" ) &
echo $! > "$R/go-c-rollback.pid"
logit "rollback armed: fires in ${ROLLBACK_SECS}s unless cancelled"

# 3. guardian: at 90 s reconnect the service; at 160 s put the address and
# route back by hand
( sleep 90
  if ! ip -4 addr show "$IFACE" 2>/dev/null | grep -q 'inet '; then
      connmanctl connect "$SVC" >> "$LOG" 2>&1
      printf '[%s] [guardian] reconnect issued\n' "$(date '+%H:%M:%S')" >> "$LOG"
  fi
  sleep 70
  if ! ip -4 addr show "$IFACE" 2>/dev/null | grep -q 'inet '; then
      ip addr add "$ADDR" dev "$IFACE" 2>/dev/null
      ip route add default via "$GW" dev "$IFACE" 2>/dev/null
      printf '[%s] [guardian] %s put back on %s\n' "$(date '+%H:%M:%S')" "$ADDR" "$IFACE" >> "$LOG"
  fi ) &
logit "guardian armed (90s reconnect, 160s $ADDR by hand)"

# 4. install the patched launcher
if ! launcher_mounted; then
    if mount --bind "$PATCHED" "$LAUNCHER"; then
        logit "launcher bind-mounted (exec line now has -r)"
    else
        logit "FAILED to mount launcher — rolling back"
        sh "$ROLLBACK"
        exit 1
    fi
fi
touch "$R/connman.sh.patched.mounted"

# 5. restart connmand — THE risky step
systemctl daemon-reload
logit "restarting connmand..."
systemctl restart connman
logit "systemctl restart connman returned rc=$?"

# 6. wait for the new connmand: running with -r and not holding
# 127.0.0.1:53, up to 90s. On a re-run the sink already holds the port, so
# "is it free" is the wrong question; "is it connmand's" is not.
n=0
while [ $n -lt 90 ]; do
    p=$(pidof connmand)
    if [ -n "$p" ] && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qE ' (-r|--nodnsproxy) ' \
        && ! connmand_on_53 "$p"; then
        logit "connmand (pid $p) runs with -r and does not hold 127.0.0.1:53 after ${n}s — proxy is OFF"
        break
    fi
    sleep 1; n=$((n + 1))
done
if [ $n -ge 90 ]; then
    logit "connmand still holds 127.0.0.1:53 (or is not running with -r) after 90s; rolling back"
    sh "$ROLLBACK"
    exit 1
fi

# 6b. wait for the link to come back (connmand restarted; guardian at 90s)
n=0
while [ $n -lt 150 ]; do
    if ip -4 addr show "$IFACE" 2>/dev/null | grep -q 'inet '; then
        logit "$IFACE has an address after ${n}s"
        break
    fi
    sleep 1; n=$((n + 1))
done
[ $n -ge 150 ] && logit "WARN: $IFACE still down after 150s - dns start may fail upstream check"

# 7. move the sink onto 127.0.0.1 (dns.bind is what every later dns.sh, the
# watchdog and the boot hook read)
logit "moving sink to 127.0.0.1:53"
echo 127.0.0.1 > "$R/dns.bind"
pkill -f watch-dns.sh 2>/dev/null
pkill -f dnssink.py 2>/dev/null; sleep 1
OYG_DNS_UPSTREAM=$UP OYG_DNS_BIND=127.0.0.1 sh "$HERE/dns.sh" start >> "$LOG" 2>&1
logit "dns.sh start rc=$?"

# 8. verify
sleep 3
blk=$(nslookup "$BLOCKED" 127.0.0.1 2>/dev/null | awk '/^Address/ && !/127.0.0.1/{print $2}' | tail -1)
ok=$(nslookup github.com 127.0.0.1 2>/dev/null | awk '/^Address/ && !/127.0.0.1/{print $2}' | tail -1)
dflt=$(nslookup "$BLOCKED" 2>/dev/null | awk '/^Address/ && !/127.0.0.1/{print $2}' | tail -1)
ip=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1)
logit "verify: via 127.0.0.1 blocked-name=$blk allowed-name=$ok | default-path=$dflt | $IFACE=$ip | connmand pid now $(pidof connmand)"
case "$blk" in
    "::"|0.0.0.0) case "$ok" in
        ""|::|0.0.0.0) logit "VERIFY FAILED: allowed name did not resolve"; sh "$ROLLBACK"; exit 1 ;;
        *) ;;
    esac ;;
    *) logit "VERIFY FAILED: blocked name not blocked via 127.0.0.1"; sh "$ROLLBACK"; exit 1 ;;
esac
[ -n "$ip" ] || { logit "VERIFY FAILED: $IFACE has no address"; sh "$ROLLBACK"; exit 1; }

# 9. success — cancel the rollback timer
tp=$(cat "$R/go-c-rollback.pid" 2>/dev/null)
[ -n "$tp" ] && kill "$tp" 2>/dev/null && rm -f "$R/go-c-rollback.pid"
touch "$R/go-c.done"
logit "=== SUCCESS: rollback cancelled. ConnMan proxy is OFF; sink owns 127.0.0.1:53 ==="
