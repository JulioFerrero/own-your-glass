# tests/lib.sh itself: every test starts unable to touch the machine running it.

test_tests_see_no_real_processes() {
    assert_eq "$(pidof sh 2>/dev/null)" ""
    assert_eq "$(pgrep -x sh 2>/dev/null)" ""
}

test_tests_cannot_mount() {
    mount --bind /dev/null "$T_TMP/x" 2>/dev/null
    umount "$T_TMP/x" 2>/dev/null
    assert_contains "$(calls)" "mount --bind /dev/null $T_TMP/x"
    assert_contains "$(calls)" "umount $T_TMP/x"
}

test_a_test_can_still_fake_a_process() {
    stub pidof 'echo 4242'
    assert_eq "$(pidof avahi-daemon)" "4242"
}

test_device_commands_do_not_exist_unless_a_test_fakes_them() {
    for c in systemctl initctl ip route iptables luna-send node nslookup chattr ps reboot kill_helper; do
        if type "$c" >/dev/null 2>&1; then
            case $(type "$c") in *builtin*) ;; *) fail "$c is reachable: $(type "$c")" ;; esac
        fi
    done
}

test_proc_scans_see_no_real_processes() {
    # shellcheck source=lib/common.sh
    . "$OYG_SRC/lib/common.sh"
    assert_eq "$(oyg_pids_matching sh)" ""
}
