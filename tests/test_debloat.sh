# debloat module, services pass, on upstart (webOS 4) and systemd (webOS 10).

# shellcheck source=tests/upstart.sh
. "$T_DIR/upstart.sh"

# The 43UM7300's debloat targets: avahi and rdxd respawn, dmost runs as
# required_dmost. The rest of the list doesn't exist on webOS 4.
_webos4() {
    PATH=$T_STUBS:/bin:/usr/bin
    stub id 'echo 0'
    stub luna-send 'echo "{\"returnValue\":true}"'
    stub mount
    upstart_stub
    upstart_job avahi-daemon running "minimal-boot-done"
    upstart_job avahi-adaptor running "started avahi-daemon"
    upstart_job rdxd running "minimal-boot-done"
    upstart_job required_dmost running "((boot-done and started connman) and started umediaserver)"
    load_module debloat
}

test_harden_stops_the_upstart_jobs() {
    _webos4
    mod_debloat_harden >"$T_TMP/out" 2>&1
    for job in avahi-daemon avahi-adaptor rdxd required_dmost; do
        assert_contains "$(calls)" "initctl stop $job"
        assert_eq "$(initctl status "$job")" "$job stop/waiting" "$job"
    done
}

test_harden_leaves_missing_jobs_alone() {
    _webos4
    mod_debloat_harden >/dev/null 2>&1
    assert_not_contains "$(calls)" "initctl stop com.webos.service.mycar"
    assert_not_contains "$(calls)" "initctl stop ninfod"
}

test_status_is_ok_after_harden() {
    _webos4
    mod_debloat_harden >/dev/null 2>&1
    out=$(mod_debloat_status 2>&1)
    assert_contains "$out" "OK       avahi-daemon"
    assert_contains "$out" "OK       dmost"
}

test_restore_starts_the_jobs_again() {
    _webos4
    mod_debloat_harden >/dev/null 2>&1
    mod_debloat_restore >/dev/null 2>&1
    for job in avahi-daemon rdxd required_dmost; do
        assert_eq "$(initctl status "$job")" "$job start/running, process 200" "$job"
    done
}

test_without_an_init_tool_the_other_passes_still_run() {
    PATH=$T_STUBS:/bin:/usr/bin
    stub id 'echo 0'
    stub luna-send 'echo "{\"returnValue\":true}"'
    load_module debloat
    mod_debloat_harden >"$T_TMP/out" 2>&1
    assert_not_contains "$(cat "$T_TMP/out")" "systemctl not found"
    assert_contains "$(calls)" "luna-send"   # pass 3 (background apps) ran
}

test_harden_on_systemd_still_uses_systemctl() {
    PATH=$T_STUBS:/bin:/usr/bin
    stub id 'echo 0'
    stub luna-send 'echo "{\"returnValue\":true}"'
    stub mount
    # shellcheck disable=SC2016 # expanded by the stub
    stub systemctl 'case $1 in list-unit-files) echo "avahi-daemon.service enabled" ;; is-active) echo active ;; is-enabled) echo enabled ;; esac'
    load_module debloat
    mod_debloat_harden >/dev/null 2>&1
    assert_contains "$(calls)" "systemctl stop avahi-daemon.service"
}

test_dry_run_does_not_report_a_kill_that_never_happened() {
    _webos4
    stub pidof 'echo 3049'
    out=$(OYG_DRY_RUN=1 mod_debloat_harden 2>&1)
    assert_not_contains "$out" "still running after TERM+KILL"
}
