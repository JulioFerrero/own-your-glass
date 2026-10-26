# lib/common.sh: services through systemd (webOS 10) or upstart (webOS 4).

# shellcheck source=tests/upstart.sh
. "$T_DIR/upstart.sh"

_lib() {
    # shellcheck source=lib/common.sh
    . "$OYG_SRC/lib/common.sh"
}

# The stub dir is first on PATH, but the host may have a real systemctl.
_no_systemctl() {
    PATH=$T_STUBS:/bin:/usr/bin
}

test_init_is_upstart_when_only_initctl_exists() {
    _no_systemctl; upstart_stub; _lib
    assert_eq "$(oyg_init)" "upstart"
}

test_init_is_systemd_when_systemctl_exists() {
    stub systemctl; upstart_stub; _lib
    assert_eq "$(oyg_init)" "systemd"
}

test_init_is_none_without_either() {
    _no_systemctl; _lib
    assert_eq "$(oyg_init)" "none"
}

test_upstart_job_names_drop_the_unit_suffix() {
    _lib
    assert_eq "$(oyg_unit_job contentminer.service)" "contentminer"
    assert_eq "$(oyg_unit_job cups-lpd.socket)" "cups-lpd"
}

test_upstart_runs_dmost_as_required_dmost() {
    _lib
    assert_eq "$(oyg_unit_job dmost.service)" "required_dmost"
}

test_upstart_unit_present_only_when_the_job_exists() {
    _no_systemctl; upstart_stub; _lib
    upstart_job contentminer running "minimal-boot-done"
    oyg_unit_present contentminer.service || fail "contentminer should be present"
    if oyg_unit_present acr.service; then fail "acr should be absent"; fi
}

test_upstart_is_active_follows_the_job_state() {
    _no_systemctl; upstart_stub; _lib
    upstart_job rdxd running "minimal-boot-done"
    upstart_job iot-client waiting "rest-boot-done"
    assert_eq "$(oyg_unit_query rdxd.service is-active)" "active"
    assert_eq "$(oyg_unit_query iot-client.service is-active)" "inactive"
    assert_eq "$(oyg_unit_query acr.service is-active)" "unknown"
}

test_upstart_is_enabled_means_started_at_boot() {
    _no_systemctl; upstart_stub; _lib
    upstart_job contentminer running "minimal-boot-done"
    upstart_job by-hand waiting ""
    assert_eq "$(oyg_unit_query contentminer.service is-enabled)" "enabled"
    assert_eq "$(oyg_unit_query by-hand.service is-enabled)" "disabled"
}

test_upstart_stop_stops_a_respawning_job() {
    _no_systemctl; upstart_stub; _lib
    upstart_job avahi-daemon running "minimal-boot-done"
    oyg_unit_stop avahi-daemon.service || fail "stop failed"
    assert_contains "$(calls)" "initctl stop avahi-daemon"
    assert_eq "$(oyg_unit_query avahi-daemon.service is-active)" "inactive"
}

test_upstart_stop_of_a_stopped_job_succeeds() {
    _no_systemctl; upstart_stub; _lib
    upstart_job iot-client waiting "rest-boot-done"
    oyg_unit_stop iot-client.service || fail "stopping a stopped job should succeed, as systemctl does"
}

test_upstart_start_starts_the_job() {
    _no_systemctl; upstart_stub; _lib
    upstart_job contentminer waiting "minimal-boot-done"
    oyg_unit_start contentminer.service || fail "start failed"
    assert_eq "$(oyg_unit_query contentminer.service is-active)" "active"
}

test_upstart_stop_in_dry_run_only_prints() {
    _no_systemctl; upstart_stub; _lib
    upstart_job contentminer running "minimal-boot-done"
    out=$(OYG_DRY_RUN=1 oyg_unit_stop contentminer.service)
    assert_eq "$out" "DRY-RUN: initctl stop contentminer"
    assert_not_contains "$(calls)" "initctl stop"
}

test_systemd_commands_are_unchanged() {
    # shellcheck disable=SC2016 # expanded by the stub
    stub systemctl 'case $1 in list-unit-files) echo "acr.service enabled" ;; is-active) echo active ;; esac'
    _lib
    oyg_unit_present acr.service || fail "acr.service should be present"
    assert_eq "$(oyg_unit_query acr.service is-active)" "active"
    oyg_unit_stop acr.service
    oyg_unit_start acr.service
    assert_contains "$(calls)" "systemctl is-active acr.service"
    assert_contains "$(calls)" "systemctl stop acr.service"
    assert_contains "$(calls)" "systemctl start acr.service"
}

test_without_an_init_tool_nothing_is_present() {
    _no_systemctl; _lib
    if oyg_unit_present acr.service; then fail "nothing should be present"; fi
    assert_eq "$(oyg_unit_query acr.service is-active)" "unknown"
    if oyg_unit_stop acr.service 2>/dev/null; then fail "stop should fail"; fi
}

test_upstart_job_between_states_is_activating_or_deactivating() {
    _no_systemctl; upstart_stub; _lib
    upstart_job rdxd running "minimal-boot-done"
    printf 'start/pre-start, process 300\nminimal-boot-done\n' >"$T_TMP/jobs/rdxd"
    assert_eq "$(oyg_unit_query rdxd.service is-active)" "activating"
    printf 'stop/killed, process 300\nminimal-boot-done\n' >"$T_TMP/jobs/rdxd"
    assert_eq "$(oyg_unit_query rdxd.service is-active)" "deactivating"
}

test_upstart_show_config_with_stop_on_and_emits_is_still_read() {
    _no_systemctl; _lib
    # shellcheck disable=SC2016 # expanded by the stub
    stub initctl 'case $1 in status) echo "rdxd stop/waiting" ;; show-config) printf "rdxd\n  stop on started start_update\n  emits rdxd-ready\n  start on minimal-boot-done\n" ;; esac'
    assert_eq "$(oyg_unit_query rdxd.service is-enabled)" "enabled"
}
