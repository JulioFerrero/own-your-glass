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
#   luna-send + awk JSON read ~0.03s
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
# oyg_luna and the JSON reader (oyg_jget/oyg_jlist): BusyBox awk, no Python.
. "$(dirname -- "$0")/../lib/common.sh"
# The region file the apps module manages (ESP in Spain, GBR in the UK, ...).
BL=$(sed -n 's/^apps.path=//p' "$OYG_ROOT/state" 2>/dev/null)
[ -n "$BL" ] || for BL in /var/preferences/com.webos.applicationManager/blockedSystemAppList/*.json; do break; done

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
# The first two rows matter on a TV the toolkit has not been set up on: the
# app runs its bundled copy of this script until Apply hardening installs it.
[ -x "$OYG_ROOT/oyg" ] \
    || printf 'SYSTEM|NA|own-your-glass is not installed yet; Apply hardening installs it\n'
if ! OYG_FORCE_UNSUPPORTED=0 oyg_supported 2>/dev/null; then
    if [ -e "$OYG_ALLOW_UNSUPPORTED" ]; then
        printf 'SYSTEM|WARN|testing mode: %s, and Apply hardening runs anyway\n' "$OYG_UNSUPPORTED"
    else
        printf 'SYSTEM|WARN|%s: Apply hardening will refuse here (Undo still works)\n' "$OYG_UNSUPPORTED"
    fi
fi
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
pid=$(cat "$OYG_ROOT/dns.pid" 2>/dev/null)
grep -q dnssink "/proc/${pid:-0}/cmdline" 2>/dev/null || pid=""
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
spec=$(sed -n "/^DEBLOAT_APPS_SPEC='/,/^'/p" "$OYG_ROOT/modules/debloat.sh" 2>/dev/null | grep '|')
if [ -n "$spec" ]; then
    fg=$(oyg_luna luna://com.webos.applicationManager/getForegroundAppInfo '{}' | oyg_jget appId)
    running=$(oyg_luna luna://com.webos.applicationManager/running '{}' | oyg_jlist running id)
    pre=$(oyg_luna luna://com.webos.service.preloadmanager/getPreloadPolicy '{}' | oyg_jlist applications id isEnabled)
    loaded=""; want=0; on=""
    for sp in $spec; do
        app=${sp%%|*}; how=${sp#*|}
        case ",$how," in *,close,*)
            [ "$app" != "$fg" ] && printf '%s\n' "$running" | grep -qxF -- "$app" && loaded="$loaded $app" ;;
        esac
        case ",$how," in *,preload,*)
            v=$(printf '%s\n' "$pre" | awk -v a="$app" '$1 == a { print $2; exit }')
            if [ -n "$v" ]; then
                want=$((want + 1))
                [ "$v" = "true" ] && on="$on $app"
            fi ;;
        esac
    done
    if [ -n "$loaded" ]; then
        printf 'DEBLOAT|WARN|loaded in the background:%s\n' "$loaded"
    else
        printf 'DEBLOAT|OK|0 unwanted apps loaded in the background\n'
    fi
    if [ "$want" -gt 0 ]; then
        if [ -n "$on" ]; then
            printf 'DEBLOAT|WARN|LG preload still on:%s\n' "$on"
        else
            printf 'DEBLOAT|OK|LG preload off for %s of %s apps\n' "$want" "$want"
        fi
    fi
fi

# ------------------------------------------------------------------ APPS ----
grp APPS "Hidden apps"
if [ -r "$BL" ]; then
    n=$(oyg_jflat <"$BL" | grep -cE '^blocked_(system_)?applist\[')
    printf 'APPS|OK|%s apps hidden from the launcher\n' "${n:-?}"
else
    printf 'APPS|FAIL|blocklist not found\n'
fi

# -------------------------------------------------------------- LAUNCHER ----
# Live values, not bookkeeping: each luna call takes ~0.04s. The settings
# list is read from the module so it is defined in one place.
grp LAUNCHER "Home screen"
if grep -q '^launcher.applied=1' "$OYG_ROOT/state" 2>/dev/null; then
    total=0; good=0
    for sp in $(sed -n "/^LAUNCHER_SETTINGS='/,/^'/p" "$OYG_ROOT/modules/launcher.sh" 2>/dev/null | grep ':'); do
        cat=${sp%%:*}; kv=${sp#*:}
        got=$(oyg_setting_get "$cat" "${kv%%=*}")
        [ -n "$got" ] || continue
        total=$((total + 1))
        [ "$got" = "${kv#*=}" ] && good=$((good + 1))
    done
    printf 'LAUNCHER|%s|%s of %s LG ad and promo settings off\n' \
        "$([ "$good" = "$total" ] && echo OK || echo FAIL)" "$good" "$total"
    hidden=$(sed -n 's/^launcher.hidden=//p' "$OYG_ROOT/state" 2>/dev/null)
    if [ -n "$hidden" ]; then
        lps=$(oyg_luna luna://com.webos.service.homelaunchpoints/listLaunchPoints '{}' | oyg_jlist launchPoints launchPointId)
        nh=0; back=0
        for lp in $hidden; do
            nh=$((nh + 1))
            printf '%s\n' "$lps" | grep -qxF -- "$lp" && back=$((back + 1))
        done
        if [ "$back" -gt 0 ]; then
            printf 'LAUNCHER|FAIL|%s of %s pushed apps are back on the app bar\n' "$back" "$nh"
        else
            printf 'LAUNCHER|OK|%s pushed apps hidden from the app bar\n' "$nh"
        fi
    fi
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
    a=$(oyg_jflat <"$f" | awk -F'\t' '$1 ~ /^statusList\[[0-9]+\]\.status$/ && $2 == "A" { n++ } END { print n + 0 }')
    acc=$((acc + ${a:-0}))
done
[ "$acc" -eq 0 ] \
    && printf 'POLICY|OK|0 of 18 consents accepted\n' \
    || printf 'POLICY|FAIL|%s consent(s) still accepted\n' "$acc"
