# install.sh: the boot hook it writes re-stops recorded services on every
# boot, through upstart on webOS 4 and systemd on webOS 10.

# shellcheck source=tests/upstart.sh
. "$T_DIR/upstart.sh"

# _install — install into $T_TMP and leave a hardened TV's stop lists there.
_install() {
    PATH=$T_STUBS:/bin:/usr/bin
    stub id 'echo 0'
    stub node
    stub ip 'echo "default via 192.168.4.1 dev wlan0"'
    OYG_DST=$T_TMP/dst INITD=$T_TMP/initd OYG_FORCE_UNSUPPORTED=1 \
        sh "$OYG_SRC/install.sh" >"$T_TMP/install.out" 2>&1 \
        || fail "install failed: $(cat "$T_TMP/install.out")"
    printf 'contentminer.service\n' >"$T_TMP/dst/services.stopped"
    printf 'avahi-daemon.service\ndmost.service\n' >"$T_TMP/dst/debloat.units.stopped"
}

_boot() {
    sh "$T_TMP/initd/oyg" >"$T_TMP/boot.out" 2>&1
}

test_boot_hook_stops_recorded_services_through_upstart() {
    _install
    upstart_stub
    upstart_job contentminer running "minimal-boot-done"
    upstart_job avahi-daemon running "minimal-boot-done"
    upstart_job required_dmost running "boot-done"
    _boot
    assert_contains "$(calls)" "initctl stop contentminer"
    assert_contains "$(calls)" "initctl stop avahi-daemon"
    assert_contains "$(calls)" "initctl stop required_dmost"
    assert_eq "$(initctl status required_dmost)" "required_dmost stop/waiting"
}

test_boot_hook_on_systemd_still_uses_systemctl() {
    _install
    stub systemctl
    _boot
    assert_contains "$(calls)" "systemctl stop contentminer.service"
    assert_contains "$(calls)" "systemctl stop dmost.service"
}

test_variant_c_refuses_without_systemd() {
    PATH=$T_STUBS:/bin:/usr/bin
    upstart_stub
    mkdir -p "$OYG_ROOT"
    if sh "$OYG_SRC/scripts/go-c.sh" >"$T_TMP/out" 2>&1 </dev/null; then
        fail "go-c.sh should refuse: $(cat "$T_TMP/out")"
    fi
    assert_contains "$(cat "$T_TMP/out")" "Variant C needs systemd"
    assert_not_contains "$(calls)" "mount"
}
