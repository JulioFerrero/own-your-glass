#!/bin/sh
# status-fast.sh — systemctl-free status, for the on-device control app.
#
# WHY THIS EXISTS
# ---------------
# `systemctl` on this TV takes ~88 SECONDS per invocation (systemd spins at
# ~90% of a core; the box has 1287 mounts because /usr and /dev are shared
# mounts and every bind propagates into all 7 app jails). `oyg status` makes
# dozens of systemctl calls, so it needs MINUTES and the app's UI just sat on
# "loading…" forever.
#
# This script answers in well under a second by using only fast primitives:
#   pidof                     ~0.09s
#   grep /proc/mounts         ~0.01s
#   readlink / sysfs          ~0.01s
#   python3 for one JSON read ~0.11s
# It deliberately checks *observable effect* (is the microphone endpoint
# bound? is the process gone?) rather than systemd's bookkeeping.
#
# OUTPUT — line-based and trivial to parse:
#   GROUP|LEVEL|TEXT
# LEVEL is one of: OK FAIL WARN NA
# A group is emitted exactly once, with a HEADER line first:
#   GROUP|HEADER|<title>
#
# Usage: status-fast.sh

OYG_ROOT=/var/lib/own-your-glass
HOSTS=$OYG_ROOT/hosts
BL=/var/preferences/com.webos.applicationManager/blockedSystemAppList/ESP.json

is_mount() {
    # A path is "mounted" iff it appears as a mount point in mountinfo
    # (field 5). Grepping for a literal /dev/null does NOT work: bind mounts
    # record the root as /null.
    awk -v p="$1" '$5 == p { found = 1 } END { exit(found ? 0 : 1) }' /proc/self/mountinfo 2>/dev/null
}

count_binds() {  # count mount points matching a path fragment
    awk -v frag="$1" '$5 ~ frag { n++ } END { print n + 0 }' /proc/self/mountinfo 2>/dev/null
}

grp() { printf '%s|HEADER|%s\n' "$1" "$2"; }

# ---------------------------------------------------------------- SYSTEM ----
grp SYSTEM "System"
printf 'SYSTEM|OK|load %s\n' "$(cut -d' ' -f1-3 /proc/loadavg | tr ' ' ',')"
mnt=$(wc -l </proc/mounts 2>/dev/null)
printf 'SYSTEM|WARN|mounts %s (systemd spins: systemctl ~88s/call)\n' "${mnt:-?}"
printf 'SYSTEM|OK|uptime %s\n' "$(cut -d. -f1 /proc/uptime | awk '{printf "%dh%02dm", $1/3600, ($1%3600)/60}')"

# --------------------------------------------------------------- NETWORK ----
grp NETWORK "Network blocking"
if is_mount /etc/hosts; then
    printf 'NETWORK|OK|/etc/hosts sinkhole bind-mounted (%s entries)\n' \
        "$(awk 'NF>=2 && $1 ~ /^(0\.0\.0\.0|::1)$/' /etc/hosts 2>/dev/null | wc -l)"
else
    printf 'NETWORK|FAIL|/etc/hosts is NOT bind-mounted\n'
fi
bh=$(ip route show 2>/dev/null | grep -c blackhole)
[ "$bh" -gt 0 ] \
    && printf 'NETWORK|OK|%s blackhole route(s) for hardcoded resolvers\n' "$bh" \
    || printf 'NETWORK|WARN|no blackhole routes\n'
printf 'NETWORK|NA|DoH/443 + DoT/853 cannot be blocked on-device (no netfilter)\n'

# ------------------------------------------------------------------- DNS ----
grp DNS "DNS sinkhole"
pid=$(pgrep -f dnssink.py 2>/dev/null | head -1)
if [ -n "$pid" ]; then
    printf 'DNS|OK|resolver running (pid %s) on 127.0.0.2:53\n' "$pid"
else
    printf 'DNS|FAIL|resolver not running\n'
fi
if is_mount /var/lib/misc/resolv.conf; then
    printf 'DNS|OK|query path redirected (resolv.conf override mounted)\n'
else
    printf 'DNS|WARN|no resolv.conf override — DNS bypasses the sink\n'
fi
up=$(grep -h '^dns.upstream=' "$OYG_ROOT/state" 2>/dev/null | cut -d= -f2)
printf 'DNS|OK|upstream %s\n' "${up:-<unknown>}"
if [ -r "$OYG_ROOT/dns-audit.log" ]; then
    printf 'DNS|OK|%s names blocked so far\n' "$(wc -l < "$OYG_ROOT/dns-audit.log")"
fi

# ------------------------------------------------------------------ MICS ----
grp MICS "Microphones"
n=$(count_binds 'pcmC[01]D[0-9]*c')
if [ "$n" -gt 0 ]; then
    printf 'MICS|OK|%s capture endpoint(s) neutralised (/dev/null)\n' "$n"
else
    printf 'MICS|FAIL|no capture endpoints are bound\n'
fi

# ----------------------------------------------------------------- VOICE ----
grp VOICE "Voice / transcription"
nv=0
for b in /usr/sbin/voiceinput /usr/sbin/voiceinput_hidraw /usr/sbin/voiceconductor; do
    is_mount "$b" && nv=$((nv + 1))
done
[ "$nv" -ge 3 ] \
    && printf 'VOICE|OK|%s voice binaries neutralised\n' "$nv" \
    || printf 'VOICE|WARN|only %s of 3 voice binaries are bound\n' "$nv"

# --------------------------------------------------------------- DEBLOAT ----
grp DEBLOAT "Debloat"
nb=0
for b in /usr/bin/com.webos.app.voice /usr/sbin/lg.thinqai.adapter /usr/sbin/airessrvallocator \
         /usr/sbin/iconnectivity /usr/sbin/uploadd /usr/palm/services/com.webos.service.dial/discovery-server.js; do
    is_mount "$b" && nb=$((nb + 1))
done
printf 'DEBLOAT|%s|%s of 6 neutralised binaries bound\n' "$([ "$nb" -ge 5 ] && echo OK || echo WARN)" "$nb"
alive=0
for p in mycar buddyconnector alwaysready ai-inference-manager avahi-daemon ruleengine wowplay uploadd; do
    [ -n "$(pidof "$p" 2>/dev/null)" ] && alive=$((alive + 1))
done
[ "$alive" -eq 0 ] \
    && printf 'DEBLOAT|OK|0 unwanted services running\n' \
    || printf 'DEBLOAT|WARN|%s unwanted service(s) running\n' "$alive"

# ------------------------------------------------------------------ APPS ----
grp APPS "Hidden apps"
if [ -r "$BL" ]; then
    n=$(python3 -c "import json;print(len(json.load(open('$BL')).get('blocked_system_applist',[])))" 2>/dev/null)
    printf 'APPS|OK|%s apps hidden from the launcher\n' "${n:-?}"
else
    printf 'APPS|FAIL|blocklist not found\n'
fi

# ---------------------------------------------------------------- POLICY ----
grp POLICY "Consents / policy"
if [ -f /var/luna/preferences/webosbrew_telnet_disabled ]; then
    printf 'POLICY|OK|telnet disabled\n'
else
    printf 'POLICY|FAIL|telnet is NOT disabled\n'
fi
if [ -f /var/luna/preferences/webosbrew_block_updates ]; then
    printf 'POLICY|OK|system-update blocker set\n'
else
    printf 'POLICY|WARN|update blocker missing\n'
fi
acc=0
for f in /mnt/lg/cmn_data/sdp/eula-service/eula.json /mnt/lg/cache/sdp/eula-service/eula.json \
         /mnt/lg/user/sdp/eula-service/eula.json; do
    [ -r "$f" ] || continue
    a=$(python3 -c "
import json
try:
    d=json.load(open('$f')); print(sum(1 for e in d.get('statusList',[]) if e.get('status')=='A'))
except Exception: print(0)
" 2>/dev/null)
    acc=$((acc + ${a:-0}))
done
[ "$acc" -eq 0 ] \
    && printf 'POLICY|OK|0 of 18 consents accepted\n' \
    || printf 'POLICY|FAIL|%s consent(s) still accepted\n' "$acc"
