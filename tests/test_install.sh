# install.sh: the boot hook it writes re-stops recorded services on every
# boot, through upstart on webOS 4 and systemd on webOS 10.

# shellcheck source=tests/upstart.sh
. "$T_DIR/upstart.sh"

# _install — install into $T_TMP and leave a hardened TV's stop lists there.
_install() {
    PATH=$T_STUBS:/bin:/usr/bin
    stub id 'echo 0'
    stub node
    stub ip 'echo "default via 192.168.1.1 dev wlan0"'
    OYG_DST=$T_TMP/dst INITD=$T_TMP/initd OYG_FORCE_UNSUPPORTED=1 \
        sh "$OYG_SRC/install.sh" >"$T_TMP/install.out" 2>&1 \
        || fail "install failed: $(cat "$T_TMP/install.out")"
    printf 'contentminer.service\n' >"$T_TMP/dst/services.stopped"
    printf 'avahi-daemon.service\ndmost.service\n' >"$T_TMP/dst/debloat.units.stopped"
}

# The hook's late pass waits OYG_HOOK_LATE_SECS (120 on a TV); 0 here so no
# test leaves a sleeper behind.
_boot() {
    OYG_HOOK_LATE_SECS=${OYG_HOOK_LATE_SECS:-0} sh "$T_TMP/initd/oyg" >"$T_TMP/boot.out" 2>&1
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
    # shellcheck disable=SC2016 # expanded by the stub
    stub systemctl 'case $1 in list-unit-files) printf "%s enabled\n" contentminer.service avahi-daemon.service dmost.service ;; esac'
    _boot
    assert_contains "$(calls)" "systemctl stop contentminer.service"
    assert_contains "$(calls)" "systemctl stop dmost.service"
}

test_variant_c_refuses_without_systemd_and_touches_nothing() {
    PATH=$T_STUBS:/bin:/usr/bin
    upstart_stub
    stub mount
    mkdir -p "$OYG_ROOT"
    printf 'previous run\n' >"$OYG_ROOT/go-c.log"
    : >"$OYG_ROOT/go-c.done"
    if sh "$OYG_SRC/scripts/go-c.sh" >"$T_TMP/out" 2>&1 </dev/null; then
        fail "go-c.sh should refuse: $(cat "$T_TMP/out")"
    fi
    assert_contains "$(cat "$T_TMP/out")" "Variant C needs systemd"
    assert_not_contains "$(calls)" "mount"
    assert_eq "$(cat "$OYG_ROOT/go-c.log")" "previous run"
    [ -e "$OYG_ROOT/go-c.done" ] || fail "go-c.done was removed"
}

test_boot_hook_without_its_library_still_runs() {
    _install
    rm "$T_TMP/dst/lib/common.sh"
    stub systemctl
    _boot
    assert_contains "$(calls)" "systemctl stop contentminer.service"
    assert_contains "$(cat "$T_TMP/dst/boot.log")" "boot-hook done"
}

test_boot_hook_tells_a_job_that_was_not_running_apart() {
    _install
    upstart_stub
    upstart_job contentminer waiting "minimal-boot-done"
    upstart_job avahi-daemon running "minimal-boot-done"
    upstart_job required_dmost running "boot-done"
    _boot
    assert_contains "$(cat "$T_TMP/dst/boot.log")" "services: contentminer.service was not running"
    assert_contains "$(cat "$T_TMP/dst/boot.log")" "debloat: stopped avahi-daemon.service"
}

test_boot_hook_late_pass_stops_a_job_upstart_started_later() {
    _install
    upstart_stub
    upstart_job contentminer waiting "rest-boot-done"
    upstart_job avahi-daemon waiting "minimal-boot-done"
    upstart_job required_dmost waiting "boot-done"
    OYG_HOOK_LATE_SECS=2 _boot
    upstart_job contentminer running "rest-boot-done"   # its start event comes after the hook
    sleep 4
    assert_eq "$(initctl status contentminer)" "contentminer stop/waiting"
    assert_contains "$(cat "$T_TMP/dst/boot.log")" "services, late: stopped contentminer.service"
}

test_network_module_skips_variant_c_without_systemd() {
    PATH=$T_STUBS:/bin:/usr/bin
    upstart_stub
    stub id 'echo 0'
    load_module network
    out=$(OYG_DNS_VARIANT_C=1 _mod_network_variant_c_harden "$OYG_SRC/scripts/dns.sh" 2>&1)
    assert_contains "$out" "Variant C skipped"
    assert_not_contains "$out" "restarting ConnMan"
}

test_boot_hook_skips_services_this_tv_does_not_have() {
    _install
    printf 'contentminer.service\nobjectdetection.service\n' >"$T_TMP/dst/services.stopped"
    upstart_stub
    upstart_job contentminer running "minimal-boot-done"
    upstart_job avahi-daemon running "minimal-boot-done"
    upstart_job required_dmost running "boot-done"
    _boot
    assert_not_contains "$(cat "$T_TMP/dst/boot.log")" "could not stop objectdetection"
    assert_contains "$(cat "$T_TMP/dst/boot.log")" "services: stopped contentminer.service"
}
