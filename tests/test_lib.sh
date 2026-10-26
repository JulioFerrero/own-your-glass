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
