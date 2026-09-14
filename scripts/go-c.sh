#!/bin/sh
# Variant C: stop ConnMan's DNS proxy (-r) so the sink can own 127.0.0.1:53.
# Runs detached; every safety net armed inside; cancels rollback on success.
R=/var/lib/own-your-glass
LOG=$R/go-c.log
STAMP=$(date '+%H:%M:%S')
logit() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> $LOG; }

: > $LOG
rm -f $R/go-c.done
logit "=== Variant C starting ==="
logit "connmand pid before: $(pidof connmand)"

# 1. rollback timer (fires in 420s unless cancelled)
pkill -f 'rollback-c.sh' 2>/dev/null
( sleep 660; sh $R/rollback-c.sh ) &
echo $! > $R/go-c-rollback.pid
logit "rollback armed: fires in 420s unless cancelled"

# 2. wifi guardian: at 90s reconnect the saved service; at 160s static IP
( sleep 90
  if ! ip -4 addr show wlan0 2>/dev/null | grep -q 'inet '; then
      connmanctl connect wifi_0827a8033128_426f7269735f3547_managed_psk_84aa9ce14e23 >> $LOG 2>&1
      printf '[%s] [guardian] wifi reconnect issued\n' "$(date '+%H:%M:%S')" >> $LOG
  fi
  sleep 70
  if ! ip -4 addr show wlan0 2>/dev/null | grep -q 'inet '; then
      ip addr add 192.168.1.240/24 dev wlan0 2>/dev/null
      ip route add default via 192.168.1.1 dev wlan0 2>/dev/null
      printf '[%s] [guardian] static IP 192.168.1.240 installed\n' "$(date '+%H:%M:%S')" >> $LOG
  fi ) &
logit "wifi guardian armed (90s reconnect, 160s static IP)"

# 3. install the patched launcher
mount --bind $R/connman.sh.patched /etc/systemd/system/scripts/connman.sh
if [ $? -eq 0 ]; then
    touch $R/connman.sh.patched.mounted
    logit "launcher bind-mounted (exec line now has -r --nodnsproxy)"
else
    logit "FAILED to mount launcher — aborting, rollback will clean"
    sh $R/rollback-c.sh
    exit 1
fi

# 4. restart connmand — THE risky step
systemctl daemon-reload
logit "restarting connmand..."
systemctl restart connman
logit "systemctl restart connman returned rc=$?"

# 5. wait for 127.0.0.1:53 to be free (proxy gone), up to 90s
n=0
while [ $n -lt 90 ]; do
    if python3 -c "
import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
try: s.bind(('127.0.0.1',53)); sys.exit(0)
except OSError: sys.exit(1)
finally: s.close()
" 2>/dev/null; then
        logit "127.0.0.1:53 is free after ${n}s — proxy is OFF"
        break
    fi
    sleep 1; n=$((n+1))
done
if [ $n -ge 90 ]; then
    logit "127.0.0.1:53 still held after 90s — nodnsproxy did not take effect; rolling back"
    sh $R/rollback-c.sh
    exit 1
fi

# 5b. wait for wifi to be back (connman restarted; guardian reconnects at 90s)
n=0
while [ $n -lt 150 ]; do
    if ip -4 addr show wlan0 2>/dev/null | grep -q "inet "; then
        logit "wlan0 has an address after ${n}s"
        break
    fi
    sleep 1; n=$((n+1))
done
[ $n -ge 150 ] && logit "WARN: wlan0 still down after 150s - dns start may fail upstream check"

# 6. move the sink onto 127.0.0.1
logit "moving sink to 127.0.0.1:53"
pkill -f watch-dns.sh 2>/dev/null
pkill -f dnssink.py 2>/dev/null; sleep 1; OYG_DNS_UPSTREAM=80.58.61.254 OYG_DNS_BIND=127.0.0.1 sh $R/scripts/dns.sh start >> $LOG 2>&1
logit "dns.sh restart rc=$?"

# 7. verify
sleep 3
blk=$(nslookup es.nextlgsdp.com 127.0.0.1 2>/dev/null | awk '/^Address/ && !/127.0.0.1/{print $2}' | tail -1)
ok=$(nslookup github.com 127.0.0.1 2>/dev/null | awk '/^Address/ && !/127.0.0.1/{print $2}' | tail -1)
dflt=$(nslookup es.nextlgsdp.com 2>/dev/null | awk '/^Address/ && !/127.0.0.1/{print $2}' | tail -1)
ip=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | head -1)
logit "verify: via127.0.0.1 blocked-name=$blk allowed-name=$ok | default-path=$dflt | wlan0=$ip | connmand pid now $(pidof connmand)"
case "$blk" in
    "::"|0.0.0.0) case "$ok" in
        ""|::|0.0.0.0) logit "VERIFY FAILED: allowed name did not resolve"; sh $R/rollback-c.sh; exit 1 ;;
        *) ;;
    esac ;;
    *) logit "VERIFY FAILED: blocked name not blocked via 127.0.0.1"; sh $R/rollback-c.sh; exit 1 ;;
esac
case "$ip" in 192.168.1.*) ;; *) logit "VERIFY FAILED: wlan0 has no address"; sh $R/rollback-c.sh; exit 1 ;; esac

# 8. success — cancel the rollback timer
tp=$(cat $R/go-c-rollback.pid 2>/dev/null)
[ -n "$tp" ] && kill $tp 2>/dev/null && rm -f $R/go-c-rollback.pid
touch $R/go-c.done
logit "=== SUCCESS: rollback cancelled. ConnMan proxy is OFF; sink owns 127.0.0.1:53 ==="
