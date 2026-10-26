# services module on upstart (webOS 4) and systemd (webOS 10).

# shellcheck source=tests/upstart.sh
. "$T_DIR/upstart.sh"

# A webOS 4 TV like the 43UM7300: contentminer runs, iot-client is stopped,
# the other targets don't exist. No systemctl; harden runs as root.
_webos4() {
    PATH=$T_STUBS:/bin:/usr/bin
    stub id 'echo 0'
    upstart_stub
    upstart_job contentminer running "minimal-boot-done"
    upstart_job iot-client waiting "rest-boot-done"
    load_module services
}

test_harden_stops_contentminer_through_upstart() {
    _webos4
    mod_services_harden >"$T_TMP/out" 2>&1 || fail "harden failed: $(cat "$T_TMP/out")"
    assert_contains "$(calls)" "initctl stop contentminer"
    assert_eq "$(oyg_unit_query contentminer.service is-active)" "inactive"
}

test_harden_records_what_it_stopped_for_the_boot_hook() {
    _webos4
    mod_services_harden >/dev/null 2>&1
    assert_contains "$(cat "$OYG_ROOT/services.stopped")" "contentminer.service"
}

test_harden_leaves_missing_jobs_alone() {
    _webos4
    mod_services_harden >/dev/null 2>&1
    assert_not_contains "$(calls)" "initctl stop acr"
    assert_not_contains "$(calls)" "initctl stop objectdetection"
}

test_status_reports_upstart_jobs() {
    _webos4
    out=$(mod_services_status 2>&1)
    assert_not_contains "$out" "systemctl not available"
    assert_contains "$out" "contentminer"
}

test_status_is_ok_after_harden() {
    _webos4
    mod_services_harden >/dev/null 2>&1
    out=$(mod_services_status 2>&1)
    assert_contains "$out" "OK       contentminer"
}

test_restore_starts_contentminer_again() {
    _webos4
    mod_services_harden >/dev/null 2>&1
    mod_services_restore >"$T_TMP/out" 2>&1
    assert_contains "$(calls)" "initctl start contentminer"
    assert_eq "$(oyg_unit_query contentminer.service is-active)" "active"
}

test_harden_on_systemd_still_uses_systemctl() {
    PATH=$T_STUBS:/bin:/usr/bin
    stub id 'echo 0'
    # shellcheck disable=SC2016 # expanded by the stub
    stub systemctl 'case $1 in list-unit-files) echo "contentminer.service enabled" ;; is-active) echo active ;; is-enabled) echo enabled ;; esac'
    load_module services
    mod_services_harden >/dev/null 2>&1
    assert_contains "$(calls)" "systemctl stop contentminer.service"
}
