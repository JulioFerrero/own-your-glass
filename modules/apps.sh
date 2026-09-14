OYG_MOD_APPS=1

# apps.sh — hide a curated list of unwanted apps from the launcher via
# {"blocked_system_applist":[...]} in blockedSystemAppList/<REGION>.json
# (read at every launcher render; hides only, never deletes; /var/preferences
# is writable). Merge curated + existing IDs, filter to present apps, write
# via temp file + mv (no python — awk/sed/tr/sort/uniq). Backup ONCE:
#    (never overwrite; a later edit cannot quietly corrupt the audit
#    trail).
# Details, verification history and findings: docs/FINDINGS.md (F41)

APPS_DIR=${APPS_DIR:-/var/preferences/com.webos.applicationManager/blockedSystemAppList}
APPS_BACKUP_DIR=${APPS_BACKUP_DIR:-"$OYG_BACKUP"}

# Curated app IDs grouped by category. Each group is a comment-only
# header followed by the IDs (one space-separated list per line for
# readability; the loader splits on whitespace).
#
# --- Ad / ACR / commercial-overlay apps (LG ad machinery) ---
APPS_GROUP_AD_ACR='
com.webos.app.acrcomponent com.webos.app.acrhdmi1 com.webos.app.acrhdmi2 com.webos.app.acrhdmi3
com.webos.app.acrhdmi4 com.webos.app.acroverlay com.webos.app.adoverlay com.webos.app.adoverlayex
com.webos.app.adhdmi1 com.webos.app.adhdmi2 com.webos.app.adhdmi3 com.webos.app.adhdmi4
com.webos.app.fooddelivery com.webos.app.fooddeliveryex com.webos.app.fooddeliveryhdmi1
com.webos.app.fooddeliveryhdmi2 com.webos.app.fooddeliveryhdmi3 com.webos.app.fooddeliveryhdmi4
com.webos.app.overlaymembership com.webos.app.videoads com.webos.app.cmp-client com.webos.app.newandhot
'
# NOTE — deliberately NOT blocked: com.webos.app.overlaycontainer* are the
# containers that host OVERLAY WINDOWS, not the ads themselves (ad/ACR
# content lives in adoverlay*/acroverlay/fooddelivery*, which we DO block).
# Blocking them killed the quick-settings panel (gear button) with no error.
# --- Vendor remote-support app (invisible; the RemoteOne front-end) ---
APPS_GROUP_REMOTE='
com.webos.app.remoteservice
'
# --- SDK example apps shipped in production (junk) ---
APPS_GROUP_SDK='
com.webos.exampleapp.enyoapp.epg com.webos.exampleapp.groupowner com.webos.exampleapp.nav
com.webos.exampleapp.qmlapp.client.negative.one com.webos.exampleapp.qmlapp.client.negative.two
com.webos.exampleapp.qmlapp.client.positive.one com.webos.exampleapp.qmlapp.client.positive.two
com.webos.exampleapp.qmlapp.discover com.webos.exampleapp.qmlapp.epg
com.webos.exampleapp.qmlapp.hbbtv com.webos.exampleapp.qmlapp.livetv com.webos.exampleapp.qmlapp.search
com.webos.exampleapp.systemui
'
# --- Demo / test / developer-only apps ---
APPS_GROUP_DEMO='
com.webos.app.store-demo com.webos.app.sync-demo com.webos.app.factorywin
com.webos.app.svcdiagnostics com.webos.app.quickrecovery com.webos.app.renewupdate
'

# State keys:
#   apps.path                       — the JSON file we manage
#   apps.region                     — the region code derived from the path
#   apps.backup                     — the backup path
#   apps.curated.total              — total curated IDs across all groups
#   apps.curated.added              — curated IDs that were added on last run
#   apps.curated.skipped            — curated IDs skipped (absent on device)
#   apps.curated.skipped.list       — space-separated skipped IDs
#   apps.existing.kept              — count of pre-existing IDs preserved
#   apps.applied                    — "1" once harden completed

# _mod_apps_glob_files
#   Echo one candidate file per line, in glob order. Used to discover
#   the region file. Empty if the directory has no JSON files yet.
_mod_apps_glob_files() {
    [ -d "$APPS_DIR" ] || return 0
    for f in "$APPS_DIR"/*.json; do
        [ -e "$f" ] || continue
        printf '%s\n' "$f"
    done
}

# _mod_apps_pick_file
#   Pick the region file to operate on:
#     1. If the directory already contains any *.json, use the first
#        one in glob order (deterministic, the existing one wins).
#     2. Otherwise pick a placeholder name based on a derived region
#        from the env (OYG_APPS_REGION), falling back to "ESP" if
#        unset.
#   Echoes the absolute file path. Creates the parent directory if
#   missing (mkdir -p; the dir is writable on this device).
_mod_apps_pick_file() {
    existing=$(_mod_apps_glob_files | head -n 1)
    if [ -n "$existing" ]; then
        printf '%s\n' "$existing"
        return 0
    fi
    region=${OYG_APPS_REGION:-ESP}
    if [ ! -d "$APPS_DIR" ]; then
        if [ "$OYG_DRY_RUN" = "1" ]; then
            printf 'DRY-RUN: mkdir -p %s\n' "$APPS_DIR" >&2
        elif ! mkdir -p "$APPS_DIR" 2>/dev/null; then
            err "apps: cannot create $APPS_DIR" >&2
            return 1
        fi
    fi
    printf '%s/%s.json\n' "$APPS_DIR" "$region"
    return 0
}

# _mod_apps_region_from_path <path>
#   Echo the region portion of <path>/<REGION>.json. Falls back to
#   "unknown" if the basename is not parseable.
_mod_apps_region_from_path() {
    p=$1
    base=$(basename -- "$p" .json 2>/dev/null)
    if [ -z "$base" ]; then
        printf 'unknown\n'
    else
        printf '%s\n' "$base"
    fi
}

# _mod_apps_extract_existing_ids <file>
#   Echo one existing ID per line from the "blocked_system_applist"
#   array in <file>, OR empty if the file is missing or has no array.
#   The LG file on this device is one minified line:
#     {"blocked_system_applist":["com.webos.app.buddy",...]}
#   Approach: pull the substring between the first "[" that follows
#   the key "blocked_system_applist" and its matching "]", then
#   normalise: strip the wrapping quotes, turn every comma+quote
#   sequence into a newline, drop leftover whitespace.
_mod_apps_extract_existing_ids() {
    f=$1
    [ -r "$f" ] || return 0
    awk '
        {
            kn = index($0, "\"blocked_system_applist\"")
            if (kn == 0) next
            rest = substr($0, kn)
            lb = index(rest, "[")
            if (lb == 0) next
            rest = substr(rest, lb + 1)
            rb = index(rest, "]")
            if (rb == 0) next
            arr = substr(rest, 1, rb - 1)
            # Now arr is like:  "id1","id2","id3"
            # Strip wrapping quotes and convert "," separators to newlines.
            gsub(/^"|"$/, "", arr)
            gsub(/","/, "\n", arr)
            gsub(/^"|"$/, "", arr)
            n = split(arr, lines, "\n")
            for (i = 1; i <= n; i++) {
                id = lines[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
                gsub(/^"|"$/, "", id)
                if (id != "" && index(id, " ") == 0) print id
            }
        }
    ' "$f" 2>/dev/null
}

# _mod_apps_collect_curated
#   Echo one curated ID per line (whitespace-separated across all
#   four groups). Blank lines and comment-only lines are skipped.
_mod_apps_collect_curated() {
    {
        printf '%s\n' "$APPS_GROUP_AD_ACR"
        printf '%s\n' "$APPS_GROUP_REMOTE"
        printf '%s\n' "$APPS_GROUP_SDK"
        printf '%s\n' "$APPS_GROUP_DEMO"
    } | awk '
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        {
            # Normalise whitespace to single newlines, then print each
            # non-empty token.
            gsub(/[[:space:]]+/, "\n")
            print
        }
    ' | awk '/./'
}

# _mod_apps_id_exists_on_device <id>
#   Echo "1" if <id> is installed on this device, "0" otherwise.
#   Canonical locations checked: /usr/palm/applications/<id> (the
#   common case) and /media/system/apps/<id> (legacy / alt).
_mod_apps_id_exists_on_device() {
    id=$1
    [ -z "$id" ] && return 0
    if [ "$OYG_DRY_RUN" = "1" ]; then
        # On the dev box we can't actually walk the device tree, so
        # optimistically say "1" — the operator wants to see the
        # planned merge, not a wall of "skipped" on the dev box.
        printf '1\n'
        return 0
    fi
    if [ -d "/usr/palm/applications/$id" ] || [ -d "/media/system/apps/$id" ]; then
        printf '1\n'
    else
        printf '0\n'
    fi
}

# _mod_apps_write_json <file> <id-list-file>
#   Write <file> as
#     {"blocked_system_applist":["id1","id2",...]}
#   using <id-list-file> as the source of IDs (one per line, already
#   sorted+deduped). Uses a temp file then mv so a partial write
#   never replaces the live file.
_mod_apps_write_json() {
    out=$1
    list=$2
    tmp=$(mktemp 2>/dev/null) || return 1
    {
        printf '{'
        printf '"blocked_system_applist":['
        first=1
        while IFS= read -r id; do
            [ -z "$id" ] && continue
            if [ "$first" = "1" ]; then
                first=0
            else
                printf ','
            fi
            printf '"%s"' "$id"
        done <"$list"
        printf ']}'
        printf '\n'
    } >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    mv "$tmp" "$out" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

mod_apps_harden() {
    require_root
    ensure_dirs

    target=$(_mod_apps_pick_file) || return 1
    region=$(_mod_apps_region_from_path "$target")
    backup="$APPS_BACKUP_DIR/blockedSystemAppList.${region}.json"

    state_put "apps.path"   "$target"
    state_put "apps.region" "$region"
    state_put "apps.backup" "$backup"

    ok "apps: managing $target (region=$region)"

    # --- 1. Back up the original once ---
    if [ ! -e "$backup" ]; then
        if [ -e "$target" ]; then
            if [ "$OYG_DRY_RUN" = "1" ]; then
                printf 'DRY-RUN: cp -p %s %s\n' "$target" "$backup" >&2
            else
                if run cp -p "$target" "$backup" 2>/dev/null; then
                    ok "apps: backed up $target to $backup"
                else
                    err "apps: could not back up $target — refusing to rewrite"
                    return 1
                fi
            fi
        else
            # No live file yet — record a sentinel backup that restore()
            # recognises as "delete the live file on restore".
            if [ "$OYG_DRY_RUN" = "1" ]; then
                printf 'DRY-RUN: write sentinel %s\n' "$backup" >&2
            else
                {
                    printf '# apps: no original %s existed at harden time\n' "$target"
                    printf 'SENTINEL=absent\n'
                } >"$backup" 2>/dev/null || warn "apps: could not write sentinel backup"
            fi
        fi
    else
        ok "apps: backup already present at $backup (preserved)"
    fi

    # --- 2. Read existing IDs (preserve anything we did not curate) ---
    if [ "$OYG_DRY_RUN" = "1" ]; then
        # In dry-run we DON'T mutate the live file. To produce a useful
        # plan, read the live IDs anyway.
        existing_ids=$(_mod_apps_extract_existing_ids "$target")
    else
        existing_ids=$(_mod_apps_extract_existing_ids "$target")
    fi

    # --- 3. Filter curated IDs to those present on the device ---
    curated_present=""
    curated_skipped=""
    curated_total=0
    while IFS= read -r id; do
        [ -z "$id" ] && continue
        curated_total=$((curated_total + 1))
        if [ "$(_mod_apps_id_exists_on_device "$id")" = "1" ]; then
            curated_present="$curated_present
$id"
        else
            curated_skipped="$curated_skipped
$id"
        fi
    done <<EOF
$(_mod_apps_collect_curated)
EOF

    # --- 4. Build the merged, sorted, deduped ID list ---
    merged=$(mktemp 2>/dev/null) || { err "apps: mktemp failed"; return 1; }
    {
        printf '%s\n' "$existing_ids"
        printf '%s\n' "$curated_present"
    } | awk '/./' | sort -u >"$merged" 2>/dev/null

    added_count=0
    existing_kept=0
    if [ -n "$curated_present" ]; then
        added_count=$(printf '%s\n' "$curated_present" | awk '/./' | wc -l | tr -d ' ')
    fi
    if [ -n "$existing_ids" ]; then
        existing_kept=$(printf '%s\n' "$existing_ids" | awk '/./' | wc -l | tr -d ' ')
    fi

    skipped_count=0
    skipped_list=""
    if [ -n "$curated_skipped" ]; then
        skipped_count=$(printf '%s\n' "$curated_skipped" | awk '/./' | wc -l | tr -d ' ')
        skipped_list=$(printf '%s\n' "$curated_skipped" | awk '/./' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    fi

    state_put "apps.curated.total"    "$curated_total"
    state_put "apps.curated.added"    "$added_count"
    state_put "apps.curated.skipped"  "$skipped_count"
    state_put "apps.curated.skipped.list" "$skipped_list"
    state_put "apps.existing.kept"    "$existing_kept"

    # --- 5. Write the new file ---
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: write merged list (%s unique IDs) to %s\n' \
            "$(awk 'END{print NR}' "$merged" 2>/dev/null)" "$target" >&2
        ok "apps: would hide $added_count curated app(s) (skipped $skipped_count absent); preserved $existing_kept pre-existing"
        rm -f "$merged" 2>/dev/null
    else
        if _mod_apps_write_json "$target" "$merged"; then
            ok "apps: wrote $target — $added_count curated added ($skipped_count skipped), $existing_kept pre-existing preserved"
            if [ "$skipped_count" -gt 0 ]; then
                warn "apps: $skipped_count curated ID(s) absent on this device (skipped): $skipped_list"
            fi
            rm -f "$merged" 2>/dev/null
        else
            rm -f "$merged" 2>/dev/null
            err "apps: failed to write $target — restore from $backup if needed"
            return 1
        fi
    fi

    state_put "apps.applied" "1"
    return 0
}

mod_apps_restore() {
    require_root

    target=$(state_get "apps.path")
    backup=$(state_get "apps.backup")

    if [ -z "$target" ]; then
        # Fall back to discovery (someone may run restore without state).
        target=$(_mod_apps_pick_file 2>/dev/null) || true
    fi
    if [ -z "$backup" ]; then
        region=$(_mod_apps_region_from_path "$target")
        backup="$APPS_BACKUP_DIR/blockedSystemAppList.${region}.json"
    fi

    rc=0

    if [ ! -e "$backup" ]; then
        warn "apps: no backup at $backup — cannot restore"
        rc=1
    elif [ ! -e "$target" ]; then
        warn "apps: $target missing; nothing to restore"
    else
        # Sentinel backup means "no original existed at harden time":
        # remove the live file instead of copying anything over it.
        if head -n 1 "$backup" 2>/dev/null | grep -q '^SENTINEL=absent'; then
            if [ "$OYG_DRY_RUN" = "1" ]; then
                printf 'DRY-RUN: rm -f %s\n' "$target" >&2
            elif run rm -f "$target" 2>/dev/null; then
                ok "apps: removed $target (no original existed; sentinel backup)"
            else
                warn "apps: could not remove $target — manual cleanup required"
                rc=1
            fi
        else
            if [ "$OYG_DRY_RUN" = "1" ]; then
                printf 'DRY-RUN: cp -p %s %s\n' "$backup" "$target" >&2
            elif run cp -p "$backup" "$target" 2>/dev/null; then
                ok "apps: restored $target from $backup"
            else
                warn "apps: cp $backup $target failed"
                rc=1
            fi
        fi
    fi

    state_drop "apps.path"
    state_drop "apps.region"
    state_drop "apps.backup"
    state_drop "apps.curated.total"
    state_drop "apps.curated.added"
    state_drop "apps.curated.skipped"
    state_drop "apps.curated.skipped.list"
    state_drop "apps.existing.kept"
    state_drop "apps.applied"

    return $rc
}

mod_apps_status() {
    target=$(state_get "apps.path")
    if [ -z "$target" ]; then
        target=$(_mod_apps_pick_file 2>/dev/null) || true
    fi
    if [ -z "$target" ] || [ ! -e "$target" ]; then
        print_status N/A "apps: target file absent ($target)"
        return
    fi

    applied=$(state_get "apps.applied")
    existing=$(_mod_apps_extract_existing_ids "$target")
    n_existing=0
    if [ -n "$existing" ]; then
        n_existing=$(printf '%s\n' "$existing" | awk '/./' | wc -l | tr -d ' ')
    fi

    # Count curated IDs present in the live list.
    curated_n=0
    curated_present_list=""
    while IFS= read -r id; do
        [ -z "$id" ] && continue
        if printf '%s\n' "$existing" | grep -Fxq -- "$id"; then
            curated_n=$((curated_n + 1))
            curated_present_list="$curated_present_list $id"
        fi
    done <<EOF
$(_mod_apps_collect_curated)
EOF
    curated_total=$(state_get "apps.curated.total")
    [ -z "$curated_total" ] && curated_total=$(_mod_apps_collect_curated | wc -l | tr -d ' ')

    added=$(state_get "apps.curated.added")
    skipped=$(state_get "apps.curated.skipped")
    skipped_list=$(state_get "apps.curated.skipped.list")
    region=$(state_get "apps.region")
    [ -z "$region" ] && region=$(_mod_apps_region_from_path "$target")

    if [ "$applied" = "1" ]; then
        if [ "$curated_n" -eq "$curated_total" ]; then
            print_status OK "apps: $n_existing blocked (region=$region, $curated_n/$curated_total curated present)"
        else
            print_status PARTIAL "apps: $n_existing blocked but only $curated_n/$curated_total curated present (region=$region)"
        fi
        return
    fi

    # Not yet applied.
    if [ "$n_existing" = "0" ]; then
        print_status N/A "apps: $target has zero blocked entries (not yet hardened)"
        return
    fi
    print_status FAIL "apps: $target has $n_existing blocked entr(y/ies) (not yet hardened; $curated_n/$curated_total curated present)"
    if [ -n "$skipped_list" ]; then
        warn "apps: $skipped curated ID(s) absent on this device last run: $skipped_list"
    fi
}
