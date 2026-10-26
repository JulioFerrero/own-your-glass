# apps module: which file hides apps, on webOS 4 and webOS 10.
# Container only: apps count as present when /usr/palm/applications/<id> exists.

PREFS=/var/preferences/com.webos.applicationManager

# _tv <sam-strings> — a TV whose app manager binary mentions <sam-strings>,
# with two curated apps installed and LG's own US block list.
_tv() {
    in_container || skip "needs a throwaway container"
    rm -rf "$PREFS" /usr/palm/applications "$T_TMP/sam"
    mkdir -p "$PREFS/blockedAppList" /usr/palm/applications/com.webos.app.adoverlay \
        /usr/palm/applications/com.webos.app.store-demo
    printf '{"blocked_applist":["com.webos.app.naver-clova"]}' >"$PREFS/blockedAppList/USA.json"
    printf '%s\n' "$@" >"$T_TMP/sam"
    APPS_SAM=$T_TMP/sam
    export APPS_SAM
    stub id 'echo 0'
    load_module apps
}

# webOS 4 (the 43UM7300's sam has blockedAppList, never blockedSystemAppList)
_webos4() { _tv "blockedAppList"; }
_webos10() { _tv "blockedSystemAppList" "blockedAppList"; }

test_webos4_hides_apps_in_the_list_sam_reads() {
    _webos4
    mod_apps_harden >"$T_TMP/out" 2>&1 || fail "harden failed: $(cat "$T_TMP/out")"
    list=$(cat "$PREFS/blockedAppList/USA.json")
    assert_contains "$list" '"blocked_applist":['
    assert_contains "$list" '"com.webos.app.adoverlay"'
    assert_contains "$list" '"com.webos.app.store-demo"'
}

test_webos4_keeps_lgs_own_entries() {
    _webos4
    mod_apps_harden >/dev/null 2>&1
    assert_contains "$(cat "$PREFS/blockedAppList/USA.json")" '"com.webos.app.naver-clova"'
}

test_webos4_writes_nothing_to_blocked_system_app_list() {
    _webos4
    mod_apps_harden >/dev/null 2>&1
    assert_eq "$(ls "$PREFS/blockedSystemAppList" 2>/dev/null)" ""
}

test_webos4_undo_restores_the_exact_file() {
    _webos4
    before=$(cksum <"$PREFS/blockedAppList/USA.json")
    mod_apps_harden >/dev/null 2>&1
    mod_apps_restore >"$T_TMP/out" 2>&1
    assert_eq "$(cksum <"$PREFS/blockedAppList/USA.json")" "$before"
}

test_webos4_status_reports_the_region_list() {
    _webos4
    mod_apps_harden >/dev/null 2>&1
    out=$(mod_apps_status 2>&1)
    assert_contains "$out" "OK       apps:"
    assert_contains "$out" "region=USA"
}

test_webos10_still_uses_blocked_system_app_list() {
    _webos10
    mod_apps_harden >/dev/null 2>&1
    assert_contains "$(cat "$PREFS/blockedSystemAppList/ESP.json")" '"blocked_system_applist":['
    assert_eq "$(cat "$PREFS/blockedAppList/USA.json")" '{"blocked_applist":["com.webos.app.naver-clova"]}'
}

test_without_sam_the_webos10_layout_is_kept() {
    _tv
    rm -f "$T_TMP/sam"
    load_module apps
    mod_apps_harden >/dev/null 2>&1
    [ -f "$PREFS/blockedSystemAppList/ESP.json" ] || fail "webOS 10 layout expected"
}

# webOS 3.9 (the 65UJ6300): sam reads blockedAppList, but the dir doesn't
# exist yet. The new list must be named after the TV's country.
test_a_new_list_is_named_after_the_tvs_country() {
    _webos4
    rm -rf "$PREFS/blockedAppList"
    stub luna-send 'echo "{\"returnValue\":true,\"settings\":{\"smartServiceCountryCode3\":\"USA\"}}"'
    load_module apps
    mod_apps_harden >"$T_TMP/out" 2>&1
    [ -f "$PREFS/blockedAppList/USA.json" ] || fail "USA.json expected: $(ls "$PREFS/blockedAppList" 2>&1)"
}

test_without_a_country_the_old_default_stays() {
    _webos4
    rm -rf "$PREFS/blockedAppList"
    stub luna-send 'echo "{\"returnValue\":false}"'
    load_module apps
    mod_apps_harden >/dev/null 2>&1
    [ -f "$PREFS/blockedAppList/ESP.json" ] || fail "ESP.json expected"
}
