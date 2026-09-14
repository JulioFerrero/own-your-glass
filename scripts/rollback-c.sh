#!/bin/sh
# Undo Variant C: restore the stock connman launcher (DNS proxy back on) and
# put the sink where it was. Needs no network.
R=/var/lib/own-your-glass
LOG=$R/go-c.log
printf '[%s] [rollback] starting\n' "$(date '+%H:%M:%S')" >> $LOG
if awk '$5=="/etc/systemd/system/scripts/connman.sh"{f=1} END{exit !f}' /proc/self/mountinfo; then
    umount /etc/systemd/system/scripts/connman.sh && printf '[%s] [rollback] stock launcher restored\n' "$(date '+%H:%M:%S')" >> $LOG
fi
rm -f $R/connman.sh.patched.mounted
systemctl daemon-reload 2>/dev/null
systemctl restart connman 2>/dev/null
printf '[%s] [rollback] connmand restarted (stock)\n' "$(date '+%H:%M:%S')" >> $LOG
export OYG_DNS_BIND=127.0.0.2
pkill -f dnssink.py 2>/dev/null; sleep 1; OYG_DNS_UPSTREAM=80.58.61.254 OYG_DNS_BIND=127.0.0.2 sh $R/scripts/dns.sh start >> $LOG 2>&1
printf '[%s] [rollback] done — sink back on 127.0.0.2\n' "$(date '+%H:%M:%S')" >> $LOG
