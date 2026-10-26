# perms module: the "not writable by group/other" check.

test_mode_without_group_or_other_write_is_safe() {
    load_module perms
    touch "$T_TMP/f" && chmod 644 "$T_TMP/f"
    assert_eq "$(_mod_perms_not_writable "$T_TMP/f" 2>&1)" "1"
}

test_group_writable_mode_is_flagged() {
    load_module perms
    touch "$T_TMP/f" && chmod 664 "$T_TMP/f"
    assert_eq "$(_mod_perms_not_writable "$T_TMP/f" 2>&1)" "0"
}

test_other_writable_dir_is_flagged() {
    load_module perms
    mkdir "$T_TMP/d" && chmod 757 "$T_TMP/d"
    assert_eq "$(_mod_perms_not_writable "$T_TMP/d" 2>&1)" "0"
}

test_missing_path_is_not_applicable() {
    load_module perms
    assert_eq "$(_mod_perms_not_writable "$T_TMP/nope" 2>&1)" "N/A"
}
