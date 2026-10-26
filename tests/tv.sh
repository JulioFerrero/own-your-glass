# tests/tv.sh — a TV-shaped filesystem for container-only tests, and a check
# that an oyg command changed nothing on it. Source from a test file.

# tv_files [fresh] — TV files at their real paths (webOS 10 shape). Without
# "fresh", also an earlier harden's state: $OYG_ROOT, blocklists, hosts copy.
tv_files() {
    # The container is shared by every test in this run: start clean.
    rm -rf /tmp/var /tmp/app.voice.log /tmp/capture.rgb /var/luna /var/lib/misc \
        /var/run/nyx /var/preferences /mnt/lg /opt/tv "$OYG_ROOT"
    mkdir -p /tmp/var/log /var/luna/preferences /var/lib/misc /var/run/nyx \
        /var/preferences/com.webos.applicationManager/blockedSystemAppList \
        /mnt/lg/cmn_data/admanager/cookie /usr/sbin /usr/bin /opt/tv
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
    printf '{"eula":[{"id":"S_VNG","accepted":true},{"id":"S_TAG","accepted":true}]}\n' \
        >/var/luna/preferences/eula
    for d in cmn_data cache user; do
        mkdir -p "/mnt/lg/$d/sdp/eula-service"
        printf '{"terms":[{"managementTypeCode":"A","accepted":true}]}\n' \
            >"/mnt/lg/$d/sdp/eula-service/eula.json"
    done
    printf '%s\n' '00-00: PCM : PCM : playback 1' '00-11: MIC : MIC : capture 1' \
        >/opt/tv/asound-pcm
    OYG_PROC_ASOUND_PCM=/opt/tv/asound-pcm
    export OYG_PROC_ASOUND_PCM

    [ "${1:-}" = "fresh" ] && return 0
    mkdir -p "$OYG_ROOT"
    cp -R "$OYG_SRC/etc" "$OYG_ROOT/etc"
    printf '127.0.0.1 localhost\n0.0.0.0 old.example\n' >"$OYG_ROOT/hosts"
    printf '%s\n' mic.applied=1 logs.applied=1 capture.applied=1 >"$OYG_ROOT/state"
}

# device_stubs — fake device commands. Reads answer; changes are logged.
device_stubs() {
    stub luna-send 'echo "{\"returnValue\":true}"'
    stub luna-send-pub 'echo "{\"returnValue\":true}"'
    # shellcheck disable=SC2016 # $1 belongs to the stub
    stub systemctl 'case $1 in is-active) echo active ;; is-enabled) echo enabled ;; esac'
    for c in mount umount ip iptables ip6tables route node; do stub "$c"; done
    [ -x "$T_STUBS/chattr" ] || stub chattr
}

# fs_state — every path outside the kernel trees, the sources and this
# test's temp dir, with mode; files also with mtime (a truncate of an empty
# file shows) and checksum.
fs_state() {
    find / \( -path /proc -o -path /sys -o -path /dev -o -path "$OYG_SRC" -o -path "$T_TMP" \) -prune \
        -o -print 2>/dev/null | sort | while IFS= read -r f; do
        if [ -f "$f" ] && [ ! -L "$f" ]; then
            printf '%s %s %s\n' "$f" "$(stat -c '%a %Y' "$f")" "$(cksum <"$f")"
        else
            printf '%s %s\n' "$f" "$(file_mode "$f" 2>/dev/null)"
        fi
    done
}

# assert_oyg_changes_nothing <oyg args...> — run oyg with every opt-in flag
# and fail on any changed file or any device-changing command.
assert_oyg_changes_nothing() {
    device_stubs
    fs_state >"$T_TMP/before"
    OYG_AGGRESSIVE=1 OYG_NETWORK_BLOCK=1 OYG_NETWORK_STRICT=1 OYG_NETWORK_IPBLOCK=1 \
        OYG_DNS_OVERRIDE=1 OYG_DNS_RESOLVER=1 OYG_LAUNCHER=1 OYG_LAUNCHER_TRIM=1 \
        sh "$OYG_SRC/oyg" "$@" >"$T_TMP/out" 2>&1
    fs_state >"$T_TMP/after"
    changed=$(diff "$T_TMP/before" "$T_TMP/after")
    [ -z "$changed" ] || fail "oyg $* changed files:
$changed"
    bad=$(grep -E '^(mount|umount|chattr) |^systemctl (stop|start|restart|reload|mask|unmask|enable|disable|daemon-reload)|^(ip|ip6tables|iptables|route) .*(add|del|replace|flush|-[AIDF] )|^luna-send(-pub)? .*/(set|kill|close|launch|hide|unhide|add|remove|delete|update)' "$T_CALLS")
    [ -z "$bad" ] || fail "oyg $* changed the device:
$bad"
}
