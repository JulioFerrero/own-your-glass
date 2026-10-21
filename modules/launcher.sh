OYG_MOD_LAUNCHER=1

# launcher.sh — a clean home screen. Opt-in (OYG_LAUNCHER=1); once applied
# the boot hook re-applies it every boot (state launcher.applied=1).
#   A settings  LG's own ad / promotion / tips / sports-alert switches, set
#               through luna://com.webos.settingsservice. The values from
#               before the first run are saved once and put back by restore.
#   B apps      apps LG pushes onto the app bar (every stub app, plus
#               LAUNCHER_HIDE_IDS) are hidden with homelaunchpoints/
#               hideLaunchPoint, and their quick cards removed.
#               OYG_LAUNCHER_KEEP="<id> ..." exempts apps.
#   C pushlist  the server-written launchpoints/<REGION>/applist.json that
#               pushes those apps (and stub installs) keeps only apps that
#               are installed and not hidden. Backed up once.
#   D layout    OYG_LAUNCHER_TRIM=1 (= wallpaper): the hero becomes a
#               wallpaper over the top two-thirds of the screen with the app
#               bar docked under it. home.xml loses the quick cards and the
#               shelves and gets a taller hero; our image is bind-mounted
#               over the hero's built-in default picture (with promotions
#               off the hero only ever shows that picture). A list of
#               section IDs instead hides just those (the black minimal
#               layout is "herobanner qcardList recommendedShelf"). Either
#               way the home is restarted to read it, and if its layout
#               parser reports an error the mounts are undone on the spot.
#               OYG_LAUNCHER_TRIM=0 puts the stock layout back; unset keeps
#               what is applied (state launcher.trim).
# Findings and on-device evidence: docs/FINDINGS.md (F45, F50).

LAUNCHER_HLP_URI=luna://com.webos.service.homelaunchpoints
LAUNCHER_SAM_URI=luna://com.webos.applicationManager

# category:key=wanted. Keys absent on a firmware are skipped.
#   homePromotion          hero + inline ad banners on the home
#   screenSaverAd          "Screen Saver Promotion" (ads in the screensaver)
#   adCookie               "Advertisement" — personalised-ad cookie
#   aiNudge                "Smart Tips" pop-ups
#   sportsAlarm            sports alerts
#   lmt                    limit ad tracking (on = limited)
#   contentRecommendation  "Content Recommendation" shelves
#   livePromotion          ads and services while watching live TV
#   livePlus               Live Plus (interactive features driven by ACR)
#   webOSPromotionVideo    webOS promotion video
LAUNCHER_SETTINGS='
general:homePromotion=off
general:screenSaverAd=off
general:adCookie=off
general:aiNudge=off
general:sportsAlarm=off
general:lmt=on
other:contentRecommendation=off
option:livePromotion=off
option:livePlus=off
option:webOSPromotionVideo=off
'

# Pushed apps that are not stubs (stubs are found at run time).
LAUNCHER_HIDE_IDS=${LAUNCHER_HIDE_IDS:-"ui30 webos.day com.miniclip.eightballpool"}

LAUNCHER_PUSHLIST_GLOB=/var/palm/customization/launchpoints/*/applist.json

LAUNCHER_HOME_APP=com.webos.app.home
LAUNCHER_HOME_XML=/usr/palm/applications/com.webos.app.home/data/flutter_assets/assets/home.xml
LAUNCHER_HOME_LOG=/tmp/var/log/home
# The hero's default picture, one per UI resolution (2k, 4k, hd, ...); the
# _network variant is shown while the TV is offline.
LAUNCHER_HERO_IMAGES=/usr/palm/applications/com.webos.app.home/data/flutter_assets/assets/images/*/bg_banner_img*.png
LAUNCHER_WALLPAPER="$OYG_ROOT/home-wallpaper.png"
# The copy next to the running oyg: the installed toolkit, or the app's
# bundle when Clean is pressed before Apply hardening ever ran.
LAUNCHER_WALLPAPER_DEFAULT="${OYG_HERE:-$OYG_ROOT}/etc/home-wallpaper.png"
# Hero (and the icon column beside it) height in home.xml units (4K: 2160
# is the full screen). The stock 900 leaves the lower half empty once the
# shelves are gone; 1450 puts the app bar near the bottom with a margin.
LAUNCHER_HERO_HEIGHT=1450
# Items the layout parser tolerates being deleted. Deleting herobanner or
# recommendedShelf makes it fail ("NoSuchMethodError: The method '[]' was
# called on null") and the home renders black, so those get zero size —
# the pattern stock quickGuide already uses. Zero size is not enough for
# qcardList: its labels still draw over the app bar.
LAUNCHER_DELETABLE="qcardList"

LAUNCHER_SETTINGS_BACKUP="$OYG_BACKUP/launcher-settings.orig"
LAUNCHER_XML_BACKUP="$OYG_BACKUP/home.xml.orig"
LAUNCHER_XML_TRIMMED="$OYG_ROOT/home.xml"

# State keys:
#   launcher.applied   1 once harden completed
#   launcher.hidden    launch point IDs this module hid
#   launcher.qcards    quick-card launch point IDs this module removed
#   launcher.trim      "wallpaper", or the sections hidden from home.xml
#                      (empty = layout untouched)

# --- A: settings -----------------------------------------------------------

_mod_launcher_settings_harden() {
    for spec in $LAUNCHER_SETTINGS; do
        cat=${spec%%:*}; rest=${spec#*:}; key=${rest%%=*}; want=${rest#*=}
        cur=$(oyg_setting_get "$cat" "$key")
        if [ -z "$cur" ]; then
            ok "launcher: setting $cat.$key not on this firmware — skipped"
            continue
        fi
        if [ "$OYG_DRY_RUN" != "1" ] && ! grep -q "^$cat:$key=" "$LAUNCHER_SETTINGS_BACKUP" 2>/dev/null; then
            printf '%s:%s=%s\n' "$cat" "$key" "$cur" >>"$LAUNCHER_SETTINGS_BACKUP"
        fi
        if [ "$cur" = "$want" ]; then
            ok "launcher: $cat.$key already $want"
        elif [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: setSystemSettings %s.%s %s -> %s\n' "$cat" "$key" "$cur" "$want"
        elif oyg_setting_set "$cat" "$key" "$want"; then
            ok "launcher: $cat.$key $cur -> $want"
        else
            warn "launcher: could not set $cat.$key (still $cur)"
        fi
    done
}

_mod_launcher_settings_restore() {
    [ -r "$LAUNCHER_SETTINGS_BACKUP" ] || { ok "launcher: no saved settings"; return 0; }
    while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        cat=${spec%%:*}; rest=${spec#*:}; key=${rest%%=*}; val=${rest#*=}
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: setSystemSettings %s.%s -> %s\n' "$cat" "$key" "$val"
        elif oyg_setting_set "$cat" "$key" "$val"; then
            ok "launcher: $cat.$key restored to $val"
        else
            warn "launcher: could not restore $cat.$key"
        fi
    done <"$LAUNCHER_SETTINGS_BACKUP"
}

# --- B: pushed apps and their quick cards ----------------------------------

# One app ID per line: every installed stub app plus LAUNCHER_HIDE_IDS,
# minus OYG_LAUNCHER_KEEP.
_mod_launcher_targets() {
    stubs=$(oyg_luna "$LAUNCHER_SAM_URI/listApps" '{}' \
        | oyg_json "[a['id'] for a in d.get('apps', []) if a.get('type') == 'stub']")
    for id in $LAUNCHER_HIDE_IDS $stubs; do
        case " ${OYG_LAUNCHER_KEEP:-} " in
            *" $id "*) continue ;;
        esac
        printf '%s\n' "$id"
    done | sort -u
}

# _mod_launcher_lp_ids <method> — "<appId> <launchPointId>" per line.
_mod_launcher_lp_ids() {
    oyg_luna "$LAUNCHER_HLP_URI/$1" '{}' \
        | oyg_json "['%s %s' % (p.get('id'), p.get('launchPointId')) for p in d.get('launchPoints', [])]"
}

_mod_launcher_apps_harden() {
    targets=$(_mod_launcher_targets)
    hidden=$(state_get launcher.hidden 2>/dev/null)
    qcards=$(state_get launcher.qcards 2>/dev/null)
    visible=$(_mod_launcher_lp_ids listLaunchPoints)
    cards=$(_mod_launcher_lp_ids listQCards)
    for id in $targets; do
        lp=$(printf '%s\n' "$visible" | awk -v i="$id" '$1 == i { print $2; exit }')
        if [ -n "$lp" ]; then
            if [ "$OYG_DRY_RUN" = "1" ]; then
                printf 'DRY-RUN: hideLaunchPoint %s\n' "$lp"
            elif oyg_luna "$LAUNCHER_HLP_URI/hideLaunchPoint" "{\"launchPointId\":\"$lp\"}" \
                    | oyg_json "d.get('returnValue')" | grep -q True; then
                ok "launcher: hid $id from the app bar ($lp)"
                case " $hidden " in *" $lp "*) ;; *) hidden="$hidden $lp" ;; esac
            else
                warn "launcher: hideLaunchPoint $lp failed"
            fi
        fi
        qc=$(printf '%s\n' "$cards" | awk -v i="$id" '$1 == i { print $2; exit }')
        if [ -n "$qc" ]; then
            if [ "$OYG_DRY_RUN" = "1" ]; then
                printf 'DRY-RUN: removeQCard %s\n' "$qc"
            elif oyg_luna "$LAUNCHER_HLP_URI/removeQCard" "{\"launchPointId\":\"$qc\"}" \
                    | oyg_json "d.get('returnValue')" | grep -q True; then
                ok "launcher: removed the quick card of $id ($qc)"
                case " $qcards " in *" $qc "*) ;; *) qcards="$qcards $qc" ;; esac
            else
                warn "launcher: removeQCard $qc failed"
            fi
        fi
    done
    [ "$OYG_DRY_RUN" = "1" ] && return 0
    state_put launcher.hidden "$(printf '%s' "$hidden" | sed 's/^ *//')"
    state_put launcher.qcards "$(printf '%s' "$qcards" | sed 's/^ *//')"
}

_mod_launcher_apps_restore() {
    for lp in $(state_get launcher.hidden 2>/dev/null); do
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: unhideLaunchPoint %s\n' "$lp"
        else
            oyg_luna "$LAUNCHER_HLP_URI/unhideLaunchPoint" "{\"launchPointId\":\"$lp\"}" >/dev/null \
                && ok "launcher: unhid $lp"
        fi
    done
    for qc in $(state_get launcher.qcards 2>/dev/null); do
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: addQCard %s\n' "$qc"
        else
            oyg_luna "$LAUNCHER_HLP_URI/addQCard" "{\"launchPointId\":\"$qc\",\"position\":0}" >/dev/null \
                && ok "launcher: quick card $qc added back"
        fi
    done
    [ "$OYG_DRY_RUN" = "1" ] && return 0
    state_drop launcher.hidden
    state_drop launcher.qcards
}

# --- C: the push list -------------------------------------------------------

_mod_launcher_pushlist_harden() {
    installed=$(oyg_luna "$LAUNCHER_SAM_URI/listApps" '{}' \
        | oyg_json "[a['id'] for a in d.get('apps', [])]")
    [ -n "$installed" ] || { warn "launcher: listApps returned nothing — push list left alone"; return 0; }
    targets=$(_mod_launcher_targets)
    for f in $LAUNCHER_PUSHLIST_GLOB; do
        [ -f "$f" ] || continue
        region=$(basename "$(dirname "$f")")
        bak="$OYG_BACKUP/launcher-applist.$region.json.orig"
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: prune %s to installed, non-hidden apps\n' "$f"
            continue
        fi
        [ -e "$bak" ] || cp -p "$f" "$bak" || { warn "launcher: cannot back up $f"; continue; }
        tmp="$f.oyg.$$"
        removed=$(printf '%s\n' "$installed" | python3 -c '
import json, sys
keep = set(sys.stdin.read().split()) - set(sys.argv[3].split())
d = json.load(open(sys.argv[1]))
gone = []
for k, v in d.items():
    if isinstance(v, list) and all(isinstance(x, str) for x in v):
        gone += [x for x in v if x not in keep]
        d[k] = [x for x in v if x in keep]
json.dump(d, open(sys.argv[2], "w"), separators=(",", ":"))
print(" ".join(gone))
' "$f" "$tmp" "$targets") && mv "$tmp" "$f" || {
            rm -f "$tmp"
            warn "launcher: could not rewrite $f"
            continue
        }
        if [ -n "$removed" ]; then
            ok "launcher: push list $region — dropped $removed"
        else
            ok "launcher: push list $region — nothing left to drop"
        fi
    done
}

_mod_launcher_pushlist_restore() {
    for bak in "$OYG_BACKUP"/launcher-applist.*.json.orig; do
        [ -f "$bak" ] || continue
        region=${bak##*/launcher-applist.}; region=${region%.json.orig}
        f=/var/palm/customization/launchpoints/$region/applist.json
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: cp %s %s\n' "$bak" "$f"
        else
            cp -p "$bak" "$f" && ok "launcher: push list $region restored"
        fi
    done
}

# --- D: layout ----------------------------------------------------------------

_mod_launcher_mounted() {
    awk -v t="$1" '$5 == t { f = 1 } END { exit !f }' /proc/self/mountinfo 2>/dev/null
}

_mod_launcher_xml_mounted() {
    _mod_launcher_mounted "$LAUNCHER_HOME_XML"
}

# _mod_launcher_hero_targets — the hero's default pictures on this firmware.
_mod_launcher_hero_targets() {
    for f in $LAUNCHER_HERO_IMAGES; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
}

# _mod_launcher_wallpaper_harden — put the wallpaper in place and mount it
# over every hero picture. Sets wchanged=1 if anything changed.
# OYG_LAUNCHER_WALLPAPER=<file> uses your own image (any size: the hero
# scales it to cover); =default goes back to the toolkit's.
_mod_launcher_wallpaper_harden() {
    wchanged=0
    src=""
    case "${OYG_LAUNCHER_WALLPAPER:-}" in
        "") [ "$(state_get launcher.wallpaper 2>/dev/null)" = "custom" ] && [ -s "$LAUNCHER_WALLPAPER" ] \
                || src=$LAUNCHER_WALLPAPER_DEFAULT ;;
        default) src=$LAUNCHER_WALLPAPER_DEFAULT; state_drop launcher.wallpaper ;;
        *) src=$OYG_LAUNCHER_WALLPAPER; state_put launcher.wallpaper custom ;;
    esac
    if [ -n "$src" ] && ! cmp -s "$src" "$LAUNCHER_WALLPAPER" 2>/dev/null; then
        [ -s "$src" ] || { warn "launcher: wallpaper $src not found"; return 1; }
        # In place (same inode), so live bind-mounts show the new picture.
        cat "$src" >"$LAUNCHER_WALLPAPER" && chmod 0644 "$LAUNCHER_WALLPAPER" || return 1
        wchanged=1
    fi
    for t in $(_mod_launcher_hero_targets); do
        _mod_launcher_mounted "$t" && continue
        run mount --bind "$LAUNCHER_WALLPAPER" "$t" || { warn "launcher: bind-mount over $t failed"; return 1; }
        wchanged=1
    done
    return 0
}

# _mod_launcher_wallpaper_restore — sets wchanged=1 if a picture came back.
_mod_launcher_wallpaper_restore() {
    wchanged=0
    for t in $(_mod_launcher_hero_targets); do
        _mod_launcher_mounted "$t" || continue
        run umount "$t" && wchanged=1
    done
}

# _mod_launcher_home_pid — the home's flutter-client (other Flutter apps
# run the same binary).
_mod_launcher_home_pid() {
    for p in $(pidof flutter-client 2>/dev/null); do
        if tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -q -- "-i $LAUNCHER_HOME_APP "; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# _mod_launcher_restart_home — closeByAppId only hides the home (a keepAlive
# app keeps its process), so the process is ended and a fresh one reads
# home.xml again (no CRIU restore). Left alone, preloadmanager starts the
# new one anywhere from 2 to 30 s later, with an empty screen meanwhile if
# the home was in front. So it is launched straight away: in front if it
# was in front, else in the background ("preload":"full", as
# preloadmanager does).
_mod_launcher_restart_home() {
    p0=$(_mod_launcher_home_pid) || return 1
    front=$(oyg_luna "$LAUNCHER_SAM_URI/getForegroundAppInfo" '{}' \
        | oyg_json "d.get('appId')")
    kill -TERM "$p0" 2>/dev/null || return 1
    n=0
    while [ -d "/proc/$p0" ] && [ "$n" -lt 50 ]; do
        sleep 0.1; n=$((n + 1))
    done
    if [ "$front" = "$LAUNCHER_HOME_APP" ]; then
        launch="{\"id\":\"$LAUNCHER_HOME_APP\"}"
    else
        launch="{\"id\":\"$LAUNCHER_HOME_APP\",\"preload\":\"full\"}"
    fi
    oyg_luna "$LAUNCHER_SAM_URI/launch" "$launch" >/dev/null
    n=0
    while [ "$n" -lt 30 ]; do
        p1=$(_mod_launcher_home_pid) && [ "$p1" != "$p0" ] && return 0
        sleep 1; n=$((n + 1))
    done
    return 1
}

# _mod_launcher_check_first_start — early in boot the home is not running
# yet (preloadmanager starts it about two minutes after power-on, later
# if the TV stays in standby), so it reads the trimmed home.xml on its
# own. This waits for that in the background and undoes the trim if the
# layout fails. It gives up if the mount goes away first.
_mod_launcher_check_first_start() {
    since=$(date '+%Y-%m-%dT%H:%M:%S')
    until _mod_launcher_home_pid >/dev/null; do
        _mod_launcher_xml_mounted || return 0
        sleep 2
    done
    if _mod_launcher_layout_ok "$since"; then
        ok "launcher: the home started with the trimmed layout"
    else
        warn "launcher: the home did not take the trimmed layout — undoing it"
        _mod_launcher_layout_restore
    fi
}

# _mod_launcher_layout_ok <since> — 0 if the home logged a parsed layout
# after <since> (%Y-%m-%dT%H:%M:%S local time: the home log's stamps end in
# "Z" but are local, same as plain `date`) and no layout error. The first
# "Unable to load asset" for <app>/home.xml is normal: the home always
# tries that path before flutter_assets.
_mod_launcher_layout_ok() {
    since=$1
    n=0
    while [ "$n" -lt 15 ]; do
        sleep 1; n=$((n + 1))
        out=$(awk -v s="[$since" 'substr($0, 1, 20) >= s' "$LAUNCHER_HOME_LOG" 2>/dev/null)
        if printf '%s\n' "$out" | grep 'readXmlFile Error' | grep -qv 'Unable to load asset'; then
            return 1
        fi
        printf '%s\n' "$out" | grep -q '\[readXmlFile\] widget' && return 0
    done
    return 1
}

_mod_launcher_layout_harden() {
    # Unset keeps what is applied: Apply hardening and the boot hook run
    # without it. 1 = the default sections, 0 = back to the stock layout.
    trim=${OYG_LAUNCHER_TRIM-$(state_get launcher.trim 2>/dev/null)}
    case "$trim" in
        # The last value is what Clean recorded before the wallpaper layout
        # (app 0.8.7 and earlier); Clean means the wallpaper now.
        1|wallpaper|"herobanner qcardList recommendedShelf") trim=wallpaper ;;
        0)
            _mod_launcher_xml_mounted || ok "launcher: layout already stock"
            _mod_launcher_layout_restore
            return 0 ;;
    esac
    if [ -z "$trim" ]; then
        ok "launcher: layout untouched (OYG_LAUNCHER_TRIM=1 turns the hero into a wallpaper over the app bar)"
        return 0
    fi
    if [ "$trim" = "wallpaper" ]; then
        desc="the wallpaper layout"
    else
        desc="$trim hidden"
    fi
    [ -f "$LAUNCHER_HOME_XML" ] || { warn "launcher: $LAUNCHER_HOME_XML not found — layout left alone"; return 0; }
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: home.xml with %s, bind-mount it, restart the home\n' "$desc"
        return 0
    fi
    # The pristine copy can only be taken while nothing is mounted over it;
    # that is every boot, so a firmware update's new home.xml is picked up.
    if _mod_launcher_xml_mounted; then
        if [ ! -e "$LAUNCHER_XML_BACKUP" ]; then
            warn "launcher: home.xml is already mounted over and no pristine copy exists — layout left alone"
            return 0
        fi
    elif [ ! -e "$LAUNCHER_XML_BACKUP" ]; then
        cp -p "$LAUNCHER_HOME_XML" "$LAUNCHER_XML_BACKUP" || { warn "launcher: cannot back up home.xml"; return 0; }
    elif ! cmp -s "$LAUNCHER_HOME_XML" "$LAUNCHER_XML_BACKUP"; then
        cp -p "$LAUNCHER_HOME_XML" "$LAUNCHER_XML_BACKUP" \
            && ok "launcher: home.xml changed since it was saved (firmware update?) — saved the new one"
    fi
    zerosize='s/itemWidth="[0-9]+"/itemWidth="0"/
s/itemHeight="[0-9]+"/itemHeight="0"/
s/focusType="[a-z]+"/focusType="none"/
s/ autoFocus="[a-z]+"//'
    if [ "$trim" = "wallpaper" ]; then
        # Quick cards and the spacer under them go; the shelves shrink to
        # nothing; the hero and the icon column beside it grow.
        script="/<item id=\"qcardList\"/d
/<item id=\"margin\"[^>]*itemHeight=\"72\"/d
/<item id=\"recommendedShelf\"/{
$zerosize
}
/<item id=\"(container|globalline|herobanner)\"/s/itemHeight=\"[0-9]+\"/itemHeight=\"$LAUNCHER_HERO_HEIGHT\"/"
    else
        del=""; zero=""
        for s in $trim; do
            case " $LAUNCHER_DELETABLE " in
                *" $s "*) del="$del|$s" ;;
                *) zero="$zero|$s" ;;
            esac
        done
        del=${del#|}; zero=${zero#|}
        script=""
        [ -n "$del" ] && script="/<item id=\"($del)\"/d"
        [ -n "$zero" ] && script="$script
/<item id=\"($zero)\"/{
$zerosize
}"
    fi
    want="$LAUNCHER_XML_TRIMMED.want.$$"
    sed -E "$script" "$LAUNCHER_XML_BACKUP" >"$want" 2>/dev/null \
        || { rm -f "$want"; warn "launcher: cannot build the trimmed home.xml"; return 0; }
    changed=0
    if ! cmp -s "$want" "$LAUNCHER_XML_TRIMMED" 2>/dev/null; then
        # In place (same inode), so a live bind-mount shows the new content.
        cat "$want" >"$LAUNCHER_XML_TRIMMED" && changed=1
    fi
    rm -f "$want"
    chmod 0644 "$LAUNCHER_XML_TRIMMED" 2>/dev/null
    if ! _mod_launcher_xml_mounted; then
        run mount --bind "$LAUNCHER_XML_TRIMMED" "$LAUNCHER_HOME_XML" \
            || { warn "launcher: bind-mount over home.xml failed"; return 0; }
        changed=1
    fi
    if [ "$trim" = "wallpaper" ]; then
        if ! _mod_launcher_wallpaper_harden; then
            warn "launcher: wallpaper not in place — undoing the layout"
            _mod_launcher_layout_restore
            return 1
        fi
    else
        _mod_launcher_wallpaper_restore
    fi
    [ "$wchanged" = "1" ] && changed=1
    state_put launcher.trim "$trim"
    [ "$changed" = "1" ] || { ok "launcher: layout already in place ($desc)"; return 0; }
    if ! _mod_launcher_home_pid >/dev/null; then
        ok "launcher: home.xml with $desc; the home is not running yet and reads it when it starts (checked in the background, result in $OYG_LOG)"
        ( trap '' HUP; _mod_launcher_check_first_start ) </dev/null >>"$OYG_LOG" 2>&1 &
        return 0
    fi
    since=$(date '+%Y-%m-%dT%H:%M:%S')
    if _mod_launcher_restart_home && _mod_launcher_layout_ok "$since"; then
        ok "launcher: home restarted with $desc"
    else
        warn "launcher: the home did not take the trimmed layout — undoing it"
        _mod_launcher_layout_restore
        return 1
    fi
}

_mod_launcher_layout_restore() {
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: umount %s and the hero pictures, restart the home\n' "$LAUNCHER_HOME_XML"
        return 0
    fi
    back=0
    if _mod_launcher_xml_mounted; then
        run umount "$LAUNCHER_HOME_XML" && { ok "launcher: stock home.xml back"; back=1; }
    fi
    _mod_launcher_wallpaper_restore
    [ "$wchanged" = "1" ] && { ok "launcher: stock hero picture back"; back=1; }
    if [ "$back" = "1" ] && _mod_launcher_home_pid >/dev/null; then
        _mod_launcher_restart_home || warn "launcher: the home did not restart — press Home"
    fi
    state_drop launcher.trim
}

# --- entry points ------------------------------------------------------------

mod_launcher_harden() {
    if [ "${OYG_LAUNCHER:-0}" != "1" ]; then
        ok "launcher: skipped (opt-in: OYG_LAUNCHER=1; add OYG_LAUNCHER_TRIM=1 for the wallpaper layout)"
        return 0
    fi
    [ "$OYG_DRY_RUN" = "1" ] || require_root
    have luna-send || { warn "launcher: luna-send missing"; return 1; }
    have python3 || { warn "launcher: python3 missing"; return 1; }
    _mod_launcher_settings_harden
    _mod_launcher_apps_harden
    _mod_launcher_pushlist_harden
    _mod_launcher_layout_harden
    [ "$OYG_DRY_RUN" = "1" ] || state_put launcher.applied 1
}

mod_launcher_restore() {
    [ "$OYG_DRY_RUN" = "1" ] || require_root
    _mod_launcher_layout_restore
    _mod_launcher_pushlist_restore
    _mod_launcher_apps_restore
    _mod_launcher_settings_restore
    [ "$OYG_DRY_RUN" = "1" ] || { state_drop launcher.applied; state_drop launcher.wallpaper; }
}

mod_launcher_status() {
    if [ "$(state_get launcher.applied 2>/dev/null)" != "1" ]; then
        print_status N/A "launcher: not applied (opt-in: OYG_LAUNCHER=1)"
        return 0
    fi
    for spec in $LAUNCHER_SETTINGS; do
        cat=${spec%%:*}; rest=${spec#*:}; key=${rest%%=*}; want=${rest#*=}
        cur=$(oyg_setting_get "$cat" "$key")
        if [ -z "$cur" ]; then
            print_status N/A "launcher: $cat.$key not on this firmware"
        elif [ "$cur" = "$want" ]; then
            print_status OK "launcher: $cat.$key=$cur"
        else
            print_status FAIL "launcher: $cat.$key=$cur (want $want)"
        fi
    done
    visible=$(_mod_launcher_lp_ids listLaunchPoints | awk '{ print $1 }')
    for id in $(_mod_launcher_targets); do
        if printf '%s\n' "$visible" | grep -qx "$id"; then
            print_status FAIL "launcher: $id still on the app bar"
        fi
    done
    print_status OK "launcher: hidden: $(state_get launcher.hidden 2>/dev/null)"
    trim=$(state_get launcher.trim 2>/dev/null)
    if [ -z "$trim" ]; then
        print_status N/A "launcher: layout untouched"
    elif ! _mod_launcher_xml_mounted; then
        print_status FAIL "launcher: layout ($trim) recorded but home.xml is not mounted over"
    elif [ "$trim" = "wallpaper" ]; then
        n=0; m=0
        for t in $(_mod_launcher_hero_targets); do
            n=$((n + 1))
            _mod_launcher_mounted "$t" && m=$((m + 1))
        done
        if [ "$m" -eq "$n" ]; then
            print_status OK "launcher: wallpaper layout ($m hero pictures replaced)"
        else
            print_status FAIL "launcher: wallpaper layout, but only $m of $n hero pictures replaced"
        fi
    else
        print_status OK "launcher: layout with $trim hidden"
    fi
}
