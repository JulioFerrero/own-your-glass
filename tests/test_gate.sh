# lib/common.sh oyg_supported: which firmware runs without testing mode.

_firmware() {
    printf '{"webos_release": "%s"}\n' "$1" >"$T_TMP/os_info.json"
    OYG_OS_INFO=$T_TMP/os_info.json
    export OYG_OS_INFO
    stub node
    # shellcheck source=lib/common.sh
    . "$OYG_SRC/lib/common.sh"
}

test_webos_10_is_supported() {
    _firmware 10.3.2
    oyg_supported 2>/dev/null || fail "$OYG_UNSUPPORTED"
}

test_webos_4_is_supported() {
    _firmware 4.10.1    # 43UM7300PUA
    oyg_supported 2>/dev/null || fail "$OYG_UNSUPPORTED"
}

test_webos_3_is_supported() {
    _firmware 3.9.3     # 65UJ6300-UA ("webOS 3.5")
    oyg_supported 2>/dev/null || fail "$OYG_UNSUPPORTED"
}

test_webos_5_to_9_still_need_testing_mode() {
    for v in 5.5.0 6.3.1 7.3.0 8.2.0 9.1.0; do
        _firmware "$v"
        if oyg_supported 2>/dev/null; then fail "webOS $v should need testing mode"; fi
        assert_contains "$OYG_UNSUPPORTED" "webOS $v"
    done
}

test_testing_mode_still_lets_webos_6_through() {
    _firmware 6.3.1
    OYG_FORCE_UNSUPPORTED=1 oyg_supported 2>/dev/null || fail "testing mode should accept webOS 6"
}

test_an_unreadable_release_is_refused() {
    _firmware ""
    if oyg_supported 2>/dev/null; then fail "an unknown release should be refused"; fi
}
