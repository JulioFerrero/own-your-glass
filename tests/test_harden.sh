# A real (not dry) harden still does its job after the dry-run fixes.
# Container only: these write to real TV paths.

test_logs_harden_empties_the_logs() {
    in_container || skip "needs a throwaway container"
    mkdir -p /tmp/var/log && printf 'transcript\n' >/tmp/var/log/messages
    load_module logs
    mod_logs_harden >/dev/null 2>&1
    assert_eq "$(wc -c </tmp/var/log/messages | tr -d ' ')" "0"
}

test_capture_harden_uses_chattr_when_it_works() {
    in_container || skip "needs a throwaway container"
    printf 'rgb' >/tmp/capture.rgb && chmod 644 /tmp/capture.rgb
    stub chattr
    load_module capture
    mod_capture_harden >/dev/null 2>&1
    assert_contains "$(calls)" "chattr +i /tmp/capture.rgb"
}

test_capture_harden_chmods_when_chattr_fails() {
    in_container || skip "needs a throwaway container"
    printf 'rgb' >/tmp/capture.rgb && chmod 644 /tmp/capture.rgb
    stub chattr 'exit 1'
    load_module capture
    mod_capture_harden >/dev/null 2>&1
    assert_eq "$(file_mode /tmp/capture.rgb)" "0"
}

test_network_harden_writes_the_hosts_file_and_binds_it() {
    in_container || skip "needs a throwaway container"
    mkdir -p "$OYG_ROOT" && cp -R "$OYG_SRC/etc" "$OYG_ROOT/etc"
    stub mount
    load_module network
    OYG_NETWORK_BLOCK=1 mod_network_layer1_harden >"$T_TMP/out" 2>&1
    assert_eq "$(head -n 1 "$OYG_ROOT/hosts")" "127.0.0.1 localhost"
    assert_contains "$(cat "$OYG_ROOT/hosts")" "0.0.0.0 "
    assert_eq "$(cksum <"$OYG_ROOT/hosts")" "$(cksum <"$OYG_ROOT/hosts.generated")"
    assert_contains "$(calls)" "mount --bind $OYG_ROOT/hosts /etc/hosts"
    n=$(grep -c '^0\.0\.0\.0 ' "$OYG_ROOT/hosts")
    assert_contains "$(cat "$T_TMP/out")" "generated $((n * 2)) hosts entries"
}

test_apps_harden_creates_the_list_dir_when_missing() {
    in_container || skip "needs a throwaway container"
    rm -rf /var/preferences/com.webos.applicationManager
    stub luna-send 'echo "{\"returnValue\":true}"'
    load_module apps
    mod_apps_harden >"$T_TMP/out" 2>&1
    [ -d /var/preferences/com.webos.applicationManager/blockedSystemAppList ] \
        || fail "dir not created: $(cat "$T_TMP/out")"
}

# A TV with no app list at all (webOS 3.9 65UJ6300): Undo must take away the
# list and the folder harden created, not copy the "no original" note there.
test_apps_undo_removes_a_list_that_did_not_exist() {
    in_container || skip "needs a throwaway container"
    rm -rf /var/preferences/com.webos.applicationManager
    mkdir -p /var/preferences/com.webos.applicationManager /usr/palm/applications/com.webos.app.adoverlay
    stub id 'echo 0'
    stub luna-send 'echo "{\"returnValue\":true}"'
    load_module apps
    mod_apps_harden >/dev/null 2>&1
    [ -f /var/preferences/com.webos.applicationManager/blockedSystemAppList/ESP.json ] || fail "harden wrote no list"
    mod_apps_restore >"$T_TMP/out" 2>&1
    assert_eq "$(ls -A /var/preferences/com.webos.applicationManager)" ""
}
