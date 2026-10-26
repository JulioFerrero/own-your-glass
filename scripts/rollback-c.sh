#!/bin/sh
# Undo Variant C: restore the stock connman launcher (DNS proxy back on) and
# put the sink where it was. Needs no network. The sink's upstream is the one
# it last used (dns.upstream in the state file), or dns.sh finds it again.
# ROLLBACK_NO_SINK=1 skips the sink restart — used by `dns.sh stop`, which
# tears the sink down right after and does not want it resurrected on .2.
R=${OYG_ROOT:-/var/lib/own-your-glass}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DNS_SH=$HERE/dns.sh
[ -r "$DNS_SH" ] || DNS_SH=$R/scripts/dns.sh
LOG=$R/go-c.log
# say — one line to go-c.log and to stdout (the control app's console when
# Undo hardening runs this).
say() { printf '[%s] [rollback] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
# online — the default route is up and a public name resolves the way the
# TV's apps resolve it (glibc, through /etc/resolv.conf).
online() {
    ip route show default 2>/dev/null | grep -q '^default' || return 1
    if type getent >/dev/null 2>&1; then
        getent hosts github.com >/dev/null 2>&1
    else
        nslookup github.com >/dev/null 2>&1
    fi
}
# go-c.done (verified success) cancels only go-c.sh's timer, which checks it
# before calling us. Every other caller (dns.sh stop, oyg restore, a failed
# go-c.sh) means it: once this ran, Variant C is off until go-c.sh runs again.
rm -f "$R/go-c.done"
say "starting"
# The sink must let go of 127.0.0.1:53 before the stock connmand starts:
# finding the port taken, connmand's proxy falls back to ::1, which does not
# answer on this TV, and every lookup fails until a reboot.
SP=$(cat "$R/dns.pid" 2>/dev/null)
[ -n "$SP" ] && grep -q dnssink "/proc/$SP/cmdline" 2>/dev/null && kill "$SP" 2>/dev/null
pkill -f 'dnssink\.' 2>/dev/null
n=0
while [ $n -lt 10 ] && grep -q ' 0100007F:0035 ' /proc/net/udp 2>/dev/null; do
    sleep 1; n=$((n + 1))
done
[ $n -ge 10 ] && kill -9 $SP 2>/dev/null
if awk '$5=="/etc/systemd/system/scripts/connman.sh"{f=1} END{exit !f}' /proc/self/mountinfo; then
    umount /etc/systemd/system/scripts/connman.sh && say "stock launcher restored"
fi
rm -f $R/connman.sh.patched.mounted
echo 127.0.0.2 > $R/dns.bind
systemctl daemon-reload 2>/dev/null
say "restarting connmand (stock; Wi-Fi drops for 7-30 s)"
T0=$(date +%s)
systemctl restart connman 2>/dev/null
say "connmand restarted (stock)"
if [ "${ROLLBACK_NO_SINK:-0}" != "1" ]; then
    UP=$(awk -F= '$1 == "dns.upstream" { sub(/^[^=]*=/, ""); print; exit }' "$R/state" 2>/dev/null)
    env ${UP:+OYG_DNS_UPSTREAM=$UP} OYG_DNS_BIND=127.0.0.2 sh "$DNS_SH" start >> $LOG 2>&1
    say "sink back on 127.0.0.2"
else
    say "sink left down (ROLLBACK_NO_SINK)"
fi
n=0
while [ $n -lt 90 ] && ! online; do
    sleep 1; n=$((n + 1))
done
if online; then
    say "internet back online $(( $(date +%s) - T0 ))s after the ConnMan restart"
else
    say "WARN: internet still offline $(( $(date +%s) - T0 ))s after the ConnMan restart"
fi
