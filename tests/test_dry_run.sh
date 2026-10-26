# --dry-run must not change anything on the TV (see tests/tv.sh).

# shellcheck source=tests/tv.sh
. "$T_DIR/tv.sh"

_use_tv() {
    in_container || skip "needs a throwaway container"
    OYG_ROOT=/var/lib/own-your-glass
    export OYG_ROOT
    tv_files
}

test_harden_dry_run_changes_nothing() {
    _use_tv
    assert_oyg_changes_nothing harden --dry-run
}

test_harden_dry_run_changes_nothing_without_chattr() {
    _use_tv
    stub chattr 'exit 1'   # no +i on this filesystem: capture falls back to chmod
    assert_oyg_changes_nothing harden --dry-run
}

test_restore_dry_run_changes_nothing() {
    _use_tv
    assert_oyg_changes_nothing restore --dry-run
}
