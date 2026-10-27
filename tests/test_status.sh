# status and verify only read (see tests/tv.sh).

# shellcheck source=tests/tv.sh
. "$T_DIR/tv.sh"

_use_tv() {
    in_container || skip "needs a throwaway container"
    OYG_ROOT=/var/lib/own-your-glass
    export OYG_ROOT
    tv_files "$@"
}

test_status_on_a_fresh_tv_changes_nothing() {
    _use_tv fresh
    assert_oyg_changes_nothing status
}

test_status_on_a_hardened_tv_changes_nothing() {
    _use_tv
    assert_oyg_changes_nothing status
}

test_status_without_an_app_list_dir_changes_nothing() {
    _use_tv
    rm -rf /var/preferences/com.webos.applicationManager/blockedSystemAppList
    assert_oyg_changes_nothing status
}

test_verify_without_an_app_list_dir_changes_nothing() {
    _use_tv
    rm -rf /var/preferences/com.webos.applicationManager/blockedSystemAppList
    assert_oyg_changes_nothing verify
}

test_status_dry_run_changes_nothing() {
    _use_tv fresh
    assert_oyg_changes_nothing status --dry-run
}

test_verify_changes_nothing() {
    _use_tv fresh
    assert_oyg_changes_nothing verify
}

test_status_dry_run_flag_reaches_the_modules() {
    _use_tv fresh
    device_stubs
    # shellcheck disable=SC2016 # $OYG_DRY_RUN belongs to the stub
    stub luna-send 'echo "dry=$OYG_DRY_RUN" >>"$T_CALLS"; echo "{\"returnValue\":true}"'
    sh "$OYG_SRC/oyg" status --dry-run >/dev/null 2>&1
    assert_not_contains "$(calls)" "dry=0"
    assert_contains "$(calls)" "dry=1"
}
