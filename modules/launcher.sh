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
            printf '%s:%s=%s\n' "$cat" "$key" "$cur" >>"$LAUNCHER_SETTINGS_BACKUP" 2>/dev/null || {
                warn "launcher: cannot record $cat.$key in $LAUNCHER_SETTINGS_BACKUP — left as $cur"
                continue
            }
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

# Settings that went back leave the backup (the next harden records what
# they are then); ones that could not be set back stay for the next restore.
_mod_launcher_settings_restore() {
    [ -r "$LAUNCHER_SETTINGS_BACKUP" ] || { ok "launcher: no saved settings"; return 0; }
    left=$(mktemp 2>/dev/null) || { warn "launcher: no temp file — settings not restored"; return 1; }
    while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        cat=${spec%%:*}; rest=${spec#*:}; key=${rest%%=*}; val=${rest#*=}
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: setSystemSettings %s.%s -> %s\n' "$cat" "$key" "$val"
        elif oyg_setting_set "$cat" "$key" "$val"; then
            ok "launcher: $cat.$key restored to $val"
        else
            warn "launcher: could not restore $cat.$key (kept in $LAUNCHER_SETTINGS_BACKUP)"
            printf '%s\n' "$spec" >>"$left"
        fi
    done <"$LAUNCHER_SETTINGS_BACKUP"
    if [ "$OYG_DRY_RUN" = "1" ]; then
        rm -f "$left"
    elif [ -s "$left" ]; then
        mv -f "$left" "$LAUNCHER_SETTINGS_BACKUP"
        return 1
    else
        rm -f "$left"
        oyg_retire_backup "$LAUNCHER_SETTINGS_BACKUP"
    fi
    return 0
}

# --- B: pushed apps and their quick cards ----------------------------------

# One app ID per line: every installed stub app plus LAUNCHER_HIDE_IDS,
# minus OYG_LAUNCHER_KEEP.
_mod_launcher_targets() {
    stubs=$(oyg_luna "$LAUNCHER_SAM_URI/listApps" '{}' \
        | oyg_jlist apps id type | awk '$2 == "stub" { print $1 }')
    for id in $LAUNCHER_HIDE_IDS $stubs; do
        case " ${OYG_LAUNCHER_KEEP:-} " in
            *" $id "*) continue ;;
        esac
        printf '%s\n' "$id"
    done | sort -u
}

# _mod_launcher_lp_ids <method> — "<appId> <launchPointId>" per line.
_mod_launcher_lp_ids() {
    oyg_luna "$LAUNCHER_HLP_URI/$1" '{}' | oyg_jlist launchPoints id launchPointId
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
                    | oyg_jok; then
                ok "launcher: hid $id from the app bar ($lp)"
                case " $hidden " in *" $lp "*) ;; *) hidden="$hidden $lp" ;; esac
            else
                warn "launcher: hideLaunchPoint $lp failed"
            fi
        fi
        # <launchPointId>@<position>, so restore puts it back where it was.
        qc=$(printf '%s\n' "$cards" | awk -v i="$id" '$1 == i { print $2 "@" (NR - 1); exit }')
        if [ -n "$qc" ]; then
            if [ "$OYG_DRY_RUN" = "1" ]; then
                printf 'DRY-RUN: removeQCard %s\n' "$qc"
            elif oyg_luna "$LAUNCHER_HLP_URI/removeQCard" "{\"launchPointId\":\"${qc%@*}\"}" \
                    | oyg_jok; then
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

# Entries that could not be put back stay in state for the next restore.
_mod_launcher_apps_restore() {
    left_lp=""; left_qc=""
    for lp in $(state_get launcher.hidden 2>/dev/null); do
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: unhideLaunchPoint %s\n' "$lp"
        elif oyg_luna "$LAUNCHER_HLP_URI/unhideLaunchPoint" "{\"launchPointId\":\"$lp\"}" | oyg_jok; then
            ok "launcher: unhid $lp"
        else
            warn "launcher: unhideLaunchPoint $lp failed"
            left_lp="$left_lp $lp"
        fi
    done
    # Lowest position first, so each card lands where it was. Entries from
    # before 0.8.12 carry no position and go first.
    for qc in $(state_get launcher.qcards 2>/dev/null | tr ' ' '\n' \
                | awk -F@ 'NF { p = 0; if (NF > 1) p = $2; print p " " $0 }' | sort -n | awk '{ print $2 }'); do
        lp=${qc%@*}; pos=0
        case "$qc" in *@*) pos=${qc##*@} ;; esac
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: addQCard %s at %s\n' "$lp" "$pos"
        elif oyg_luna "$LAUNCHER_HLP_URI/addQCard" "{\"launchPointId\":\"$lp\",\"position\":$pos}" | oyg_jok; then
            ok "launcher: quick card $lp added back at position $pos"
        else
            warn "launcher: addQCard $lp failed"
            left_qc="$left_qc $qc"
        fi
    done
    [ "$OYG_DRY_RUN" = "1" ] && return 0
    if [ -n "$left_lp$left_qc" ]; then
        state_put launcher.hidden "$(printf '%s' "$left_lp" | sed 's/^ *//')"
        state_put launcher.qcards "$(printf '%s' "$left_qc" | sed 's/^ *//')"
        return 1
    fi
    state_drop launcher.hidden
    state_drop launcher.qcards
}

# --- C: the push list -------------------------------------------------------

# _mod_launcher_prune <file> <out> <hidden IDs> — the push list with only
# the installed IDs (stdin) that are not hidden; prints the dropped IDs.
# Only rewrites the shape LG writes, {"<key>":["<id>",...],...}, and fails
# on anything else so the file is left alone.
_mod_launcher_prune() {
    flat=$(oyg_jflat <"$1") || return 1
    [ -n "$flat" ] || return 1
    printf '%s\n' "$flat" | awk -F'\t' '
        $1 ~ /^[^.[]+\[[0-9]+\]$/ && $2 !~ /["\\]/ { next }
        $1 ~ /^[^.[]+$/ && $2 == "[]" { next }
        { bad = 1 } END { exit bad }' || return 1
    grep -q '[[,][[:space:]]*[^]"[:space:]]' "$1" && return 1    # a non-string element
    keep=$(mktemp 2>/dev/null) || return 1
    cat >"$keep"
    printf '%s\n' $3 | awk -v k="$keep" '
        BEGIN { while ((getline l < k) > 0) keep[l] = 1 }
        { delete keep[$0] }
        END { for (i in keep) print i }' >"$keep.2" && mv "$keep.2" "$keep"
    printf '%s\n' "$flat" | awk -F'\t' -v k="$keep" -v out="$2" '
        BEGIN { while ((getline l < k) > 0) keep[l] = 1 }
        {
            key = $1; sub(/\[.*/, "", key)
            if (!(key in seen)) { seen[key] = 1; order[++m] = key; ids[key] = "" }
            if ($2 == "[]" && $1 == key) next
            if ($2 in keep) {
                if (ids[key] != "") ids[key] = ids[key] ","
                ids[key] = ids[key] "\"" $2 "\""
            } else {
                if (gone != "") gone = gone " "
                gone = gone $2
            }
        }
        END {
            s = "{"
            for (i = 1; i <= m; i++) {
                if (i > 1) s = s ","
                s = s "\"" order[i] "\":[" ids[order[i]] "]"
            }
            print s "}" > out
            print gone
        }'
    rc=$?
    rm -f "$keep"
    return $rc
}

_mod_launcher_pushlist_harden() {
    installed=$(oyg_luna "$LAUNCHER_SAM_URI/listApps" '{}' | oyg_jlist apps id)
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
        removed=$(printf '%s\n' "$installed" | _mod_launcher_prune "$f" "$tmp" "$targets") \
            && oyg_mode_like "$f" "$tmp" "$bak" && mv "$tmp" "$f" || {
            rm -f "$tmp"
            warn "launcher: $f left as it is (not the shape this module rewrites, or not writable)"
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
    prc=0
    for bak in "$OYG_BACKUP"/launcher-applist.*.json.orig; do
        [ -f "$bak" ] || continue
        region=${bak##*/launcher-applist.}; region=${region%.json.orig}
        f=/var/palm/customization/launchpoints/$region/applist.json
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: cp %s %s\n' "$bak" "$f"
        elif cp -p "$bak" "$f"; then
            ok "launcher: push list $region restored"
            oyg_retire_backup "$bak"
        else
            warn "launcher: could not restore $f (backup kept at $bak)"
            prc=1
        fi
    done
    return $prc
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
    front=$(oyg_luna "$LAUNCHER_SAM_URI/getForegroundAppInfo" '{}' | oyg_jget appId)
    kill -TERM "$p0" 2>/dev/null || return 1
    n=0
    while [ -d "/proc/$p0" ] && [ "$n" -lt 50 ]; do
        oyg_nap 0.1; n=$((n + 1))
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

# A new home takes the screen once it is up, even preloaded. So while
# another app is on screen (the control app running Apply or Undo, or a
# show), the restart waits until you are back on the home; until then the
# home keeps its current layout.
# The pending restart is a file, not state: the waiter runs beside the job
# that started it, and state writes take no lock. "<token> <pid>"; the
# waiter gives up as soon as the token is not its own.
LAUNCHER_WAITER_PID="$OYG_ROOT/launcher-home.pid"

_mod_launcher_front() {
    oyg_luna "$LAUNCHER_SAM_URI/getForegroundAppInfo" '{}' | oyg_jget appId
}

_mod_launcher_cancel_deferred() {
    wp=$(awk '{ print $2 }' "$LAUNCHER_WAITER_PID" 2>/dev/null)
    rm -f "$LAUNCHER_WAITER_PID"
    [ -n "$wp" ] && grep -q oyg "/proc/$wp/cmdline" 2>/dev/null && kill "$wp" 2>/dev/null
    return 0
}

# _mod_launcher_restart_now <check> — restart the home; with <check>=1, make
# sure it took the trimmed layout and undo the layout if not.
_mod_launcher_restart_now() {
    since=$(date '+%Y-%m-%dT%H:%M:%S')
    if _mod_launcher_restart_home; then
        [ "$1" = "1" ] || return 0
        _mod_launcher_layout_ok "$since" && { ok "launcher: home restarted with $desc"; return 0; }
    elif [ "$1" != "1" ]; then
        warn "launcher: the home did not restart — press Home"
        return 1
    fi
    warn "launcher: the home did not take the trimmed layout — undoing it"
    _mod_launcher_layout_restore
    return 1
}

# _mod_launcher_restart_or_defer <check> — now if the home or nothing is on
# screen, else in the background once the home is (polled every 2 s, for up
# to 30 min; after that the next boot shows the layout).
_mod_launcher_restart_or_defer() {
    _mod_launcher_cancel_deferred
    front=$(_mod_launcher_front)
    if [ -z "$front" ] || [ "$front" = "$LAUNCHER_HOME_APP" ]; then
        _mod_launcher_restart_now "$1"
        return
    fi
    ok "launcher: the home shows the new layout once you are back on it ($front is on screen)"
    token="$(date +%s).$$"
    printf '%s\n' "$token" >"$LAUNCHER_WAITER_PID"
    ( trap '' HUP
      mine() { [ "$(awk '{ print $1 }' "$LAUNCHER_WAITER_PID" 2>/dev/null)" = "$token" ]; }
      n=0
      while [ "$n" -lt 900 ]; do
          sleep 2; n=$((n + 1))
          mine || exit 0
          f=$(_mod_launcher_front)
          [ -z "$f" ] || [ "$f" = "$LAUNCHER_HOME_APP" ] || continue
          rm -f "$LAUNCHER_WAITER_PID"
          log "launcher: back on the home — restarting it for the new layout"
          _mod_launcher_restart_now "$1"
          exit 0
      done
      mine && rm -f "$LAUNCHER_WAITER_PID"
      log "launcher: the home was not on screen for 30 min — the next boot shows the new layout" ) </dev/null >>"$OYG_LOG" 2>&1 &
    printf '%s %s\n' "$token" "$!" >"$LAUNCHER_WAITER_PID"
    return 0
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
    _mod_launcher_restart_or_defer 1
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
    state_drop launcher.trim
    if [ "$back" = "1" ] && _mod_launcher_home_pid >/dev/null; then
        _mod_launcher_restart_or_defer 0
    else
        _mod_launcher_cancel_deferred
    fi
}

# --- entry points ------------------------------------------------------------

mod_launcher_harden() {
    if [ "${OYG_LAUNCHER:-0}" != "1" ]; then
        ok "launcher: skipped (opt-in: OYG_LAUNCHER=1; add OYG_LAUNCHER_TRIM=1 for the wallpaper layout)"
        return 0
    fi
    [ "$OYG_DRY_RUN" = "1" ] || require_root
    have luna-send || { warn "launcher: luna-send missing"; return 1; }
    _mod_launcher_settings_harden
    _mod_launcher_apps_harden
    _mod_launcher_pushlist_harden
    _mod_launcher_layout_harden
    [ "$OYG_DRY_RUN" = "1" ] || state_put launcher.applied 1
}

mod_launcher_restore() {
    [ "$OYG_DRY_RUN" = "1" ] || require_root
    lrc=0
    _mod_launcher_layout_restore || lrc=1
    _mod_launcher_pushlist_restore || lrc=1
    _mod_launcher_apps_restore || lrc=1
    _mod_launcher_settings_restore || lrc=1
    [ "$OYG_DRY_RUN" = "1" ] || { state_drop launcher.applied; state_drop launcher.wallpaper; }
    return $lrc
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
