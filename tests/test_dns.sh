# DNS helpers against BusyBox 1.24's nslookup (webOS 4) and a newer one.
#
# 1.24.1 takes only `nslookup [HOST] [SERVER]`: any -option prints usage and
# fails. It numbers its answers ("Address 1: ...") where newer builds print
# "Address: ...". The server's own address comes first in both, and is not an
# answer. 9.9.9.9 stands in for the server so a leak shows up.

# Stub bodies expand when the stub runs; the variables are read by dns.sh.
# shellcheck disable=SC2016,SC2034

_nslookup_answers='
case $host in
    es.nextlgsdp.com) addrs="0.0.0.0 ::" ;;
    www.youtube.com|pub.example) addrs="93.184.216.34 2606:2800::1" ;;
    priv.example) addrs="10.0.0.5" ;;
    *) echo "nslookup: can'"'"'t resolve '"'"'$host'"'"'" >&2; exit 1 ;;
esac'

# nslookup_old — BusyBox 1.24.1: no options, numbered addresses.
nslookup_old() {
    stub nslookup '
for a in "$@"; do
    case $a in
        -*) echo "BusyBox v1.24.1 multi-call binary."; echo "Usage: nslookup [HOST] [SERVER]"; exit 1 ;;
    esac
done
host=$1
'"$_nslookup_answers"'
printf "Server:    9.9.9.9\nAddress 1: 9.9.9.9 dns.example\n\nName:      %s\n" "$host"
n=0
for a in $addrs; do n=$((n + 1)); echo "Address $n: $a"; done'
}

# nslookup_new — a newer BusyBox: options accepted, "Address:" lines.
nslookup_new() {
    stub nslookup '
while [ $# -gt 0 ]; do
    case $1 in -*) shift ;; *) break ;; esac
done
host=$1
'"$_nslookup_answers"'
printf "Server:\t\t9.9.9.9\nAddress:\t9.9.9.9#53\n\nName:\t%s\n" "$host"
for a in $addrs; do echo "Address: $a"; done'
}

# sink_node — node, as far as the sink probe goes: --probe succeeds while
# $T_TMP/sink_up exists.
sink_node() {
    stub node '[ "$2" = "--probe" ] && [ -f "$T_TMP/sink_up" ]'
}

_load_dns() {
    PATH=$T_STUBS:$T_BIN
    stub id 'echo 0'
    OYG_DNS_LIB=1
    # shellcheck source=scripts/dns.sh
    . "$OYG_SRC/scripts/dns.sh"
    # the sink's script and address, as the code under test reads them
    RESOLVER=$OYG_SRC/scripts/dnssink.js
    DNS_BIND=127.0.0.2
}

test_answers_skip_the_server_block_on_busybox_1_24() {
    nslookup_old
    # shellcheck source=lib/common.sh
    . "$OYG_SRC/lib/common.sh"
    got=$(nslookup pub.example | oyg_dns_answers)
    assert_eq "$got" "93.184.216.34
2606:2800::1"
}

test_answers_skip_the_server_block_on_newer_busybox() {
    nslookup_new
    # shellcheck source=lib/common.sh
    . "$OYG_SRC/lib/common.sh"
    got=$(nslookup -timeout=1 pub.example 9.9.9.9 | oyg_dns_answers)
    assert_eq "$got" "93.184.216.34
2606:2800::1"
}

test_answers_are_empty_when_the_name_does_not_resolve() {
    nslookup_old
    # shellcheck source=lib/common.sh
    . "$OYG_SRC/lib/common.sh"
    got=$(nslookup nope.example 2>/dev/null | oyg_dns_answers)
    assert_eq "$got" ""
}

test_layer3_resolves_a_public_name_on_busybox_1_24() {
    PATH=$T_STUBS:$T_BIN
    nslookup_old
    load_module network
    assert_eq "$(_mod_network_resolve pub.example)" "93.184.216.34"
    assert_not_contains "$(calls)" "nslookup -"
}

test_layer3_resolves_a_public_name_on_newer_busybox() {
    PATH=$T_STUBS:$T_BIN
    nslookup_new
    load_module network
    assert_eq "$(_mod_network_resolve pub.example)" "93.184.216.34"
}

test_layer3_drops_sinkhole_private_and_server_addresses() {
    PATH=$T_STUBS:$T_BIN
    load_module network
    for flavour in nslookup_old nslookup_new; do
        $flavour
        assert_eq "$(_mod_network_resolve es.nextlgsdp.com)" "" "blocked name, $flavour"
        assert_eq "$(_mod_network_resolve priv.example)" "" "private answer, $flavour"
        assert_eq "$(_mod_network_resolve nope.example)" "" "no answer, $flavour"
    done
}

test_the_sink_probe_asks_node_not_nslookup() {
    _load_dns
    nslookup_old
    sink_node
    : >"$T_TMP/sink_up"
    oyg_sink_probe "$RESOLVER" 127.0.0.2 53 || fail "probe failed with the sink up"
    assert_contains "$(calls)" "node $RESOLVER --probe 127.0.0.2 53 es.nextlgsdp.com"
    assert_not_contains "$(calls)" "nslookup"
    rm -f "$T_TMP/sink_up"
    ! oyg_sink_probe "$RESOLVER" 127.0.0.2 53 || fail "probe passed with the sink down"
}

test_the_start_up_wait_sees_the_sink_on_busybox_1_24() {
    _load_dns
    nslookup_old
    sink_node
    : >"$T_TMP/sink_up"
    _probe_resolver_direct || fail "start-up probe missed a sink that is up"
    assert_not_contains "$(calls)" "nslookup"
    rm -f "$T_TMP/sink_up"
    ! _probe_resolver_direct || fail "start-up probe passed with no sink"
}

test_resolver_alive_works_on_busybox_1_24() {
    _load_dns
    nslookup_old
    sink_node
    sleep 30 &
    sinkpid=$!
    mkdir -p "$OYG_ROOT"
    echo "$sinkpid" >"$STATE_PID"
    : >"$T_TMP/sink_up"
    ok=0
    resolver_alive && ok=1
    rm -f "$T_TMP/sink_up"
    down=0
    resolver_alive || down=1
    kill "$sinkpid" 2>/dev/null
    assert_eq "$ok" 1 "sink up"
    assert_eq "$down" 1 "sink down"
}

test_resolver_alive_without_node_trusts_the_pid() {
    _load_dns
    PATH=$T_STUBS:$T_BIN
    sleep 30 &
    sinkpid=$!
    mkdir -p "$OYG_ROOT"
    echo "$sinkpid" >"$STATE_PID"
    ok=0
    resolver_alive && ok=1
    kill "$sinkpid" 2>/dev/null
    assert_eq "$ok" 1
}

test_default_path_check_works_on_busybox_1_24() {
    _load_dns
    nslookup_old
    _verify_default_path || fail "blocked 0.0.0.0, allowed 93.184.216.34 should pass"
    assert_not_contains "$(calls)" "nslookup -"
}

test_default_path_check_works_on_newer_busybox() {
    _load_dns
    nslookup_new
    _verify_default_path || fail "blocked 0.0.0.0, allowed 93.184.216.34 should pass"
}

test_dns_test_command_queries_without_options() {
    _load_dns
    nslookup_old
    sink_node
    sleep 30 &
    sinkpid=$!
    mkdir -p "$OYG_ROOT"
    echo "$sinkpid" >"$STATE_PID"
    : >"$T_TMP/sink_up"
    out=$(cmd_test pub.example 2>&1)
    kill "$sinkpid" 2>/dev/null
    assert_contains "$out" "93.184.216.34"
    assert_not_contains "$out" "Usage: nslookup"
}

test_rescue_script_reads_busybox_124_answers() {
    out=$(printf 'Server:    127.0.0.1\nAddress 1: 127.0.0.1 localhost\n\nName:      github.com\nAddress 1: 140.82.112.4 lb-140-82-112-4-iad.github.com\n' \
        | awk '/^Name:/ { n = 1; next }
        n && /^Address/ { sub(/^Address[ 0-9]*:[ \t]*/, ""); sub(/[ \t#].*/, ""); print }' | tail -n 1)
    assert_eq "$out" "140.82.112.4"
    grep -q 'sub(/^Address\[ 0-9\]\*:' "$OYG_SRC/scripts/recover-network.sh" || fail "recover-network.sh no longer uses this parser"
}
