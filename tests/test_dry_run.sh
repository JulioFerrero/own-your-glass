# --dry-run must not change anything on the TV.
#
# Runs only inside a throwaway container: it lays out TV-shaped files at
# their real paths, records the state of the whole filesystem, runs oyg with
# every opt-in flag, and compares. Commands that change the device without
# writing a file (mount, chattr, systemctl stop, luna set*) are stubs, and
# any call to them fails the test.

_tv_files() {
    # The container is shared by every test in this run: start clean.
    rm -rf /tmp/var /tmp/app.voice.log /tmp/capture.rgb /var/luna /var/lib/misc \
        /var/run/nyx /var/preferences /mnt/lg "$OYG_ROOT"
    mkdir -p /tmp/var/log /var/luna/preferences /var/lib/misc /var/run/nyx \
        /var/preferences/com.webos.applicationManager/blockedSystemAppList \
        /mnt/lg/cmn_data/admanager/cookie /usr/sbin /usr/bin
    printf 'Oct 26 voice transcript\n' >/tmp/var/log/messages
    printf 'voice\n' >/tmp/app.voice.log
    printf 'rgb' >/tmp/capture.rgb && chmod 644 /tmp/capture.rgb
    printf '#!/bin/sh\n' >/usr/bin/vtCaptureTestSuite && chmod 755 /usr/bin/vtCaptureTestSuite
    for b in voiceinput voiceconductor uploadd performer nlpmanager iconnectivity amazon-alexa-adapter; do
        printf '#!/bin/sh\n' >"/usr/sbin/$b" && chmod 755 "/usr/sbin/$b"
    done
    printf '{"webos_release": "10.3.2"}\n' >/var/run/nyx/os_info.json
    printf '{"blocked_system_applist":["com.example.kept"]}\n' \
        >/var/preferences/com.webos.applicationManager/blockedSystemAppList/ESP.json
    printf 'cookie\n' >/mnt/lg/cmn_data/admanager/cookie/ad_cookie
    printf 'nameserver 192.168.4.1\n' >/var/lib/misc/resolv.conf

    # As if an earlier harden had run: our state dir, blocklists, hosts copy.
    mkdir -p "$OYG_ROOT"
    cp -R "$OYG_SRC/etc" "$OYG_ROOT/etc"
    printf '127.0.0.1 localhost\n0.0.0.0 old.example\n' >"$OYG_ROOT/hosts"
}

_device_stubs() {
    stub luna-send 'echo "{\"returnValue\":true}"'
    stub luna-send-pub 'echo "{\"returnValue\":true}"'
    # shellcheck disable=SC2016 # $1 belongs to the stub
    stub systemctl 'case $1 in is-active) echo active ;; is-enabled) echo enabled ;; esac'
    for c in mount umount ip iptables ip6tables route; do stub "$c"; done
    [ -x "$T_STUBS/chattr" ] || stub chattr
}

# _fs_state — every path outside the kernel trees, the sources and this
# test's temp dir, with mode and checksum.
_fs_state() {
    find / \( -path /proc -o -path /sys -o -path /dev -o -path "$OYG_SRC" -o -path "$T_TMP" \) -prune \
        -o -print 2>/dev/null | sort | while IFS= read -r f; do
        if [ -f "$f" ] && [ ! -L "$f" ]; then
            printf '%s %s %s\n' "$f" "$(file_mode "$f")" "$(cksum <"$f")"
        else
            printf '%s %s\n' "$f" "$(file_mode "$f" 2>/dev/null)"
        fi
    done
}

_assert_no_device_calls() {
    bad=$(grep -E '^(mount|umount|chattr) |^systemctl (stop|start|restart|reload|mask|unmask|enable|disable|daemon-reload)|^(ip|ip6tables|iptables|route) .*(add|del|replace|flush|-[AIDF] )|^luna-send(-pub)? .*/(set|kill|close|launch|hide|unhide|add|remove|delete|update)' "$T_CALLS")
    [ -z "$bad" ] || fail "dry run changed the device:
$bad"
}

_run_dry() {
    OYG_ROOT=/var/lib/own-your-glass
    export OYG_ROOT
    _tv_files
    _device_stubs
    before=$(_fs_state)
    OYG_AGGRESSIVE=1 OYG_NETWORK_BLOCK=1 OYG_NETWORK_STRICT=1 OYG_NETWORK_IPBLOCK=1 \
        OYG_DNS_OVERRIDE=1 OYG_DNS_RESOLVER=1 OYG_LAUNCHER=1 OYG_LAUNCHER_TRIM=1 \
        sh "$OYG_SRC/oyg" "$1" --dry-run >"$T_TMP/out" 2>&1
    after=$(_fs_state)
    changed=$(printf '%s\n' "$before" >"$T_TMP/before"; printf '%s\n' "$after" >"$T_TMP/after"; diff "$T_TMP/before" "$T_TMP/after")
    [ -z "$changed" ] || fail "oyg $1 --dry-run changed files:
$changed"
    _assert_no_device_calls
}

test_harden_dry_run_changes_nothing() {
    in_container || skip "needs a throwaway container"
    _run_dry harden
}

test_harden_dry_run_changes_nothing_without_chattr() {
    in_container || skip "needs a throwaway container"
    stub chattr 'exit 1'   # no +i on this filesystem: capture falls back to chmod
    _run_dry harden
}

test_restore_dry_run_changes_nothing() {
    in_container || skip "needs a throwaway container"
    _run_dry restore
}
