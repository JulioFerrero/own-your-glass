#!/bin/sh
# status-fast.sh — systemctl-free status, for the on-device control app.
#
# WHY THIS EXISTS
# ---------------
# `oyg status` walks every module with `systemctl` per unit and takes tens of
# seconds; polling it from a UI opened a new call before the last returned, and
# those stacked up until they saturated systemd (274 orphans, and systemctl went
# from 0.02s to ~88s per call — see the note in the app). This script answers in
# under a second by using only fast primitives and checking observable effect.
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

# setting <category> <key> — a settingsservice value (~0.04s per call).
setting() {
    luna-send -n 1 -w 3000 -f luna://com.webos.settingsservice/getSystemSettings \
        "{\"category\":\"$1\",\"keys\":[\"$2\"]}" </dev/null 2>/dev/null \
        | sed -n "s/.*\"$2\": \"\{0,1\}\([a-zA-Z0-9]*\)\"\{0,1\}.*/\1/p" | head -n 1
}

# ---------------------------------------------------------------- SYSTEM ----
grp SYSTEM "System"
printf 'SYSTEM|OK|load %s\n' "$(cut -d' ' -f1-3 /proc/loadavg | tr ' ' ',')"
mnt=$(wc -l </proc/mounts 2>/dev/null)
printf 'SYSTEM|OK|%s mounts (binds propagate into the 7 app jails)\n' "${mnt:-?}"
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
bind=$(cat "$OYG_ROOT/dns.bind" 2>/dev/null || echo 127.0.0.2)
if [ -n "$pid" ]; then
    printf 'DNS|OK|resolver running (pid %s) on %s:53\n' "$pid" "$bind"
else
    printf 'DNS|FAIL|resolver not running\n'
fi
if is_mount /etc/resolv.conf || is_mount /var/lib/misc/resolv.conf; then
    printf 'DNS|OK|query path redirected (resolv.conf override mounted)\n'
    if [ "$(grep -c '^nameserver' /etc/resolv.conf 2>/dev/null)" = "1" ]; then
        printf 'DNS|OK|resolv.conf lists only the sink\n'
    else
        printf 'DNS|WARN|resolv.conf also lists the upstream — apps that query every server bypass the sink\n'
    fi
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
# The binary list comes from the installed module, so it cannot drift.
nb=0; nt=0
for b in $(sed -n "/^DEBLOAT_BINARIES_SPEC='/,/^'/p" "$OYG_ROOT/modules/debloat.sh" 2>/dev/null \
           | grep '^/' | cut -d'|' -f1); do
    [ -e "$b" ] || continue
    nt=$((nt + 1))
    is_mount "$b" && nb=$((nb + 1))
done
printf 'DEBLOAT|%s|%s of %s neutralised binaries bound\n' "$([ "$nb" -ge "$nt" ] && echo OK || echo WARN)" "$nb" "$nt"
alive=""
for p in mycar buddyconnector alwaysready ai-inference-manager avahi-daemon ruleengine wowplay uploadd \
         dmost rdxd ninfod service-logger amazon-alexa-adapter performer nlpmanager sportsalarm; do
    [ -n "$(pidof "$p" 2>/dev/null)" ] && alive="$alive $p"
done
[ -z "$alive" ] \
    && printf 'DEBLOAT|OK|0 unwanted services running\n' \
    || printf 'DEBLOAT|WARN|still running:%s\n' "$alive"
# Background apps, also read from the installed module: none loaded behind
# what is on screen, and LG's preload off for the ones marked "preload".
sed -n "/^DEBLOAT_APPS_SPEC='/,/^'/p" "$OYG_ROOT/modules/debloat.sh" 2>/dev/null | grep '|' |
python3 -c '
import json, subprocess, sys
def luna(uri):
    try:
        p = subprocess.Popen(["luna-send", "-n", "1", "-w", "5000", uri, "{}"],
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return json.loads(p.communicate(timeout=8)[0] or b"{}")
    except Exception:
        return {}
spec = [l.split("|", 1) for l in sys.stdin.read().split()]
if not spec:
    sys.exit(0)
fg = luna("luna://com.webos.applicationManager/getForegroundAppInfo").get("appId")
running = {a.get("id") for a in luna("luna://com.webos.applicationManager/running").get("running", [])}
pre = {a.get("id"): a.get("isEnabled")
       for a in luna("luna://com.webos.service.preloadmanager/getPreloadPolicy").get("applications", [])}
loaded = [a for a, how in spec if "close" in how.split(",") and a in running and a != fg]
want = [a for a, how in spec if "preload" in how.split(",") and a in pre]
on = [a for a in want if pre[a]]
if loaded:
    print("DEBLOAT|WARN|loaded in the background: " + " ".join(loaded))
else:
    print("DEBLOAT|OK|0 unwanted apps loaded in the background")
if want:
    if on:
        print("DEBLOAT|WARN|LG preload still on: " + " ".join(on))
    else:
        print("DEBLOAT|OK|LG preload off for %d of %d apps" % (len(want), len(want)))
'

# ------------------------------------------------------------------ APPS ----
grp APPS "Hidden apps"
if [ -r "$BL" ]; then
    n=$(python3 -c "import json;print(len(json.load(open('$BL')).get('blocked_system_applist',[])))" 2>/dev/null)
    printf 'APPS|OK|%s apps hidden from the launcher\n' "${n:-?}"
else
    printf 'APPS|FAIL|blocklist not found\n'
fi

# -------------------------------------------------------------- LAUNCHER ----
# Live values, not bookkeeping: each luna call takes ~0.04s. The settings
# list is read from the module so it is defined in one place.
grp LAUNCHER "Home screen"
if grep -q '^launcher.applied=1' "$OYG_ROOT/state" 2>/dev/null; then
    sed -n "/^LAUNCHER_SETTINGS='/,/^'/p" "$OYG_ROOT/modules/launcher.sh" 2>/dev/null | grep ':' |
    python3 -c '
import json, subprocess, sys
def luna(uri, params):
    try:
        p = subprocess.Popen(["luna-send", "-n", "1", "-w", "5000", uri, json.dumps(params)],
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return json.loads(p.communicate(timeout=8)[0] or b"{}")
    except Exception:
        return {}
want = {}
for l in sys.stdin.read().split():
    cat, kv = l.split(":", 1)
    k, v = kv.split("=", 1)
    want.setdefault(cat, {})[k] = v
total = good = 0
for cat, kv in want.items():
    got = luna("luna://com.webos.settingsservice/getSystemSettings",
               {"category": cat, "keys": list(kv)}).get("settings", {})
    for k, v in kv.items():
        if k in got:
            total += 1
            good += got[k] == v
lvl = "OK" if good == total else "FAIL"
print("LAUNCHER|%s|%d of %d LG ad and promo settings off" % (lvl, good, total))
hidden = sys.argv[1].split()
if hidden:
    lps = luna("luna://com.webos.service.homelaunchpoints/listLaunchPoints", {}).get("launchPoints", [])
    back = [p for p in lps if p.get("launchPointId") in hidden]
    if back:
        print("LAUNCHER|FAIL|%d of %d pushed apps are back on the app bar" % (len(back), len(hidden)))
    else:
        print("LAUNCHER|OK|%d pushed apps hidden from the app bar" % len(hidden))
' "$(sed -n 's/^launcher.hidden=//p' "$OYG_ROOT/state" 2>/dev/null)"
else
    printf 'LAUNCHER|WARN|LG ad settings and pushed apps untouched (Apply hardening handles them)\n'
fi
trim=$(sed -n 's/^launcher.trim=//p' "$OYG_ROOT/state" 2>/dev/null)
if [ -z "$trim" ]; then
    printf 'LAUNCHER|NA|stock layout (Home screen: Clean sets the wallpaper layout)\n'
elif ! is_mount /usr/palm/applications/com.webos.app.home/data/flutter_assets/assets/home.xml; then
    printf 'LAUNCHER|FAIL|clean layout recorded but not in place\n'
elif [ "$trim" = "wallpaper" ]; then
    # Anchored: the same pictures are mounted again inside every app jail.
    imgs=/usr/palm/applications/com.webos.app.home/data/flutter_assets/assets/images
    n=$(awk -v d="$imgs/" 'index($5, d) == 1 && $5 ~ /bg_banner_img/ { print $5 }' /proc/self/mountinfo 2>/dev/null | sort -u | wc -l)
    t=$(ls "$imgs"/*/bg_banner_img*.png 2>/dev/null | wc -l)
    printf 'LAUNCHER|%s|wallpaper layout, apps docked below (%s of %s hero pictures replaced)\n' \
        "$([ "$n" -ge "$t" ] && [ "$n" -gt 0 ] && echo OK || echo FAIL)" "$n" "$t"
else
    printf 'LAUNCHER|OK|clean layout: %s hidden\n' "$trim"
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
[ "$(setting option hbbTV)" = "off" ] \
    && printf 'POLICY|OK|HbbTV red-button apps off\n' \
    || printf 'POLICY|WARN|HbbTV on (red-button apps load third-party trackers)\n'
if [ "$(setting network allowMobileDeviceAccess)" = "false" ] && is_mount /etc/xinetd.d/ssg_https; then
    printf 'POLICY|OK|phone remote control (SSAP, port 3001) off\n'
else
    printf 'POLICY|WARN|phone remote control (SSAP, port 3001) reachable from the LAN\n'
fi
if [ -e /mnt/lg/cmn_data/admanager/cookie/ad_cookie ]; then
    is_mount /mnt/lg/cmn_data/admanager/cookie/ad_cookie \
        && printf 'POLICY|OK|LG ad cookie emptied\n' \
        || printf 'POLICY|WARN|LG ad cookie in place\n'
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
