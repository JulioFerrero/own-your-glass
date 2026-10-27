# tests/lib.sh — helpers sourced by tests/run.sh before each test.

# Plain tools a test may use for real. Nothing that reaches a device,
# a service or a process (systemctl, initctl, ip, mount, luna-send, ps, ...):
# those exist in a test only as stubs it adds itself.
T_TOOLS="sh awk sed grep cat ls mkdir rm rmdir mv cp ln chmod stat mktemp date tr cut
head tail wc sort uniq basename dirname find cksum cmp diff sleep touch readlink tee
xargs env expr od id uname printf echo true false test sync timeout nohup"

# t_setup — fresh temp dir, OYG_ROOT inside it, and a PATH of stubs plus the
# plain tools above. Everything is removed when the test's subshell exits,
# Ctrl-C too. pidof, pgrep, mount and umount start as stubs, so a test
# finds no real process by name and reaches no service, mount or luna call
# unless it stubs the command. The one /proc scan a module does (debloat's
# cmd: match) only matches LG's iotjs running familycare, never a dev box.
t_setup() {
    T_TMP=$(mktemp -d "${TMPDIR:-/tmp}/oyg-test.XXXXXX") || exit 1
    trap 'rm -rf "$T_TMP"' EXIT
    trap 'exit 130' HUP INT TERM
    OYG_ROOT="$T_TMP/oyg-root"
    T_STUBS="$T_TMP/stubs"
    T_BIN="$T_TMP/bin"
    T_CALLS="$T_TMP/calls.log"
    mkdir -p "$T_STUBS" "$T_BIN"
    : >"$T_CALLS"
    for _tool in $T_TOOLS; do
        _path=$(command -v "$_tool" 2>/dev/null) || continue
        case $_path in /*) ln -s "$_path" "$T_BIN/$_tool" ;; esac
    done
    PATH="$T_STUBS:$T_BIN"
    export OYG_ROOT T_CALLS PATH
    for c in pidof pgrep; do stub "$c" 'exit 1'; done
    for c in mount umount; do stub "$c"; done
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# skip <reason> — end the test without running it (shown as "skip").
skip() {
    printf 'SKIP: %s\n' "$*"
    exit 0
}

# in_container — true only in a throwaway container started for these tests
# (docker run -e OYG_TEST_CONTAINER=1 ...): such tests create and delete
# files at real TV paths (/var/luna, /mnt/lg, /usr/sbin, ...).
in_container() {
    [ "${OYG_TEST_CONTAINER:-0}" = "1" ] && [ -f /.dockerenv ]
}

assert_eq() {
    [ "$1" = "$2" ] || fail "${3:-values differ}: expected [$2], got [$1]"
}

assert_contains() {
    case $1 in
        *"$2"*) ;;
        *) fail "${3:-missing text}: [$2] not in [$1]" ;;
    esac
}

assert_not_contains() {
    case $1 in
        *"$2"*) fail "${3:-unexpected text}: [$2] found in [$1]" ;;
    esac
}

# stub <name> [body] — a fake command on PATH. Every call is logged to
# $T_CALLS as "<name> <args>", then <body> runs (default: succeed quietly).
stub() {
    cat >"$T_STUBS/$1" <<EOF
#!/bin/sh
echo "$1 \$*" >>"\$T_CALLS"
${2:-:}
EOF
    chmod +x "$T_STUBS/$1"
}

# calls — what the stubs were called with, one call per line.
calls() {
    cat "$T_CALLS"
}

# load_module <name> — source lib/common.sh and one module, as oyg does.
load_module() {
    # shellcheck disable=SC2153 # OYG_SRC is set by tests/run.sh
    # shellcheck source=lib/common.sh
    . "$OYG_SRC/lib/common.sh"
    # shellcheck disable=SC2034 # read by the sourced code
    MODULES_DIR="$OYG_SRC/modules"
    # shellcheck source=/dev/null
    . "$OYG_SRC/modules/$1.sh"
}

# file_mode <path> — octal permission bits (GNU/BusyBox or BSD stat).
file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# tree_state <dir> — one line per entry: path, mode and checksum. Compare
# before/after to prove a command wrote nothing under <dir>.
tree_state() {
    (cd "$1" && find . | sort | while IFS= read -r f; do
        if [ -f "$f" ]; then
            printf '%s %s %s\n' "$f" "$(file_mode "$f")" "$(cksum <"$f")"
        else
            printf '%s %s\n' "$f" "$(file_mode "$f")"
        fi
    done)
}
