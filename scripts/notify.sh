#!/bin/sh
# notify.sh — send a native webOS toast to the TV.
#
# Runs ON the TV (local, `luna-send` in PATH) or FROM the computer
# (remote, ssh $TV_HOST); the two are mutually exclusive. Used by
# `oyg list`/operators to push status toasts and as the tripwire for
# the luna-send/LS2 stdin trap (--selftest).
#
# === luna-send stdin trap — load-bearing ===
# `luna-send` reads its reply on a pipe fed from STDIN. If STDIN closes
# before the reply arrives, rc=0 with ZERO bytes — the call looks fine
# but the reply is lost. Every luna-send call in this script ends with
# `</dev/null` (local: ours; remote: the TV's). Do not remove it.
#   A $( ) + stdin=/dev/null      bytes=108   ← the fix
#   B $( ) + stdin=inherited      bytes=0     ← the broken case
# Full story: docs/VERIFICATION-REPORT.md §0.1.

set -eu

TV_USER=${TV_USER:-root}
TV_PORT=${TV_PORT:-22}
NOTIFY_STATE_PATH="/var/lib/own-your-glass/notify.last"
DEFAULT_SOURCE_ID="com.webos.surfacemanager"

have()         { command -v "$1" >/dev/null 2>&1; }
log()          { printf '[notify] %s\n' "$*"; }
warn()         { printf '[notify] WARN %s\n' "$*" >&2; }
err()          { printf '[notify] ERR  %s\n' "$*" >&2; }
json_escape()  { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
sh_quote_sed() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

SSH_BASE="ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
# luna <uri> <payload> [appid] — local or ssh, always with </dev/null>.
luna() {
    uri=$1; payload=$2; appid_arg=${3:-}; af=""
    [ -n "$appid_arg" ] && af=" -a '$appid_arg'"
    if [ "$LOCAL_MODE" = "1" ]; then
        # shellcheck disable=SC2086
        luna-send -i -n 1 -f "$uri"$af "$payload" </dev/null
    else
        rp=$(sh_quote_sed "$payload")
        $SSH_BASE -p "$TV_PORT" "$TV_USER@$TV_HOST" \
            "luna-send -i -n 1 -f $uri$af '$rp' </dev/null"
    fi
}

send() {
    reply=$(luna "$1" "$2" "${3:-}") || rc=$?
    : "${rc:=0}"
    if [ -z "$reply" ] || ! printf '%s' "$reply" | grep -q '"returnValue": *true'; then
        err "luna-send $1 did not return success (rc=$rc)"
        err "  raw reply: $reply"
        err "  zero bytes = stdin trap; see docs/VERIFICATION-REPORT.md §0.1"
        exit 4
    fi
    printf '%s' "$reply"
}

state_path() {
    if [ "$LOCAL_MODE" != "1" ] \
        || { [ -w "$NOTIFY_STATE_PATH" ] || [ -w "$(dirname -- "$NOTIFY_STATE_PATH")" ]; } 2>/dev/null
    then
        printf '%s\n' "$NOTIFY_STATE_PATH"
    else
        mktemp -t notify.last.XXXXXX 2>/dev/null \
            || printf '%s/notify.last.%s' "${TMPDIR:-/tmp}" "$$"
    fi
}
write_remembered() {
    sp=$(state_path)
    if [ "$LOCAL_MODE" = "1" ]; then
        printf '%s\n' "$1" > "$sp" 2>/dev/null \
            || warn "could not write $sp (non-fatal)"
    else
        $SSH_BASE -p "$TV_PORT" "$TV_USER@$TV_HOST" \
            "printf '%s\\n' '$1' > '$sp' 2>/dev/null" >/dev/null 2>&1 \
            || warn "could not write $sp on TV (non-fatal)"
    fi
}
read_remembered() {
    if [ "$LOCAL_MODE" = "1" ]; then
        cat "$(state_path)" 2>/dev/null || true
    else
        $SSH_BASE -p "$TV_PORT" "$TV_USER@$TV_HOST" \
            "cat '$NOTIFY_STATE_PATH' 2>/dev/null || true"
    fi
}
probe_ssh() {
    if $SSH_BASE -p "$TV_PORT" "$TV_USER@$TV_HOST" \
            'echo OYG_NOTIFY_OK' >/dev/null 2>&1; then return 0; fi
    err "host $TV_HOST unreachable or auth failed for $TV_USER"
    err "  - is the TV on and reachable from this machine?"
    err "  - did you ssh-copy-id your key (see README 'Rooting your TV')?"
    err "  - try: ssh $TV_USER@$TV_HOST"
    return 1
}
# Tripwire. Empty reply == stdin trap; we do NOT require returnValue:true.
do_selftest() {
    reply=$(luna 'luna://com.webos.service.bus/getServiceAPIVersions' \
        '{"serviceName":"com.webos.notification"}') || rc=$?
    if [ -n "$reply" ]; then
        log "selftest OK — bus replied ($(printf '%s' "$reply" | wc -c | tr -d ' ') bytes)"
        log "  reply: $reply"
        exit 0
    fi
    err "selftest FAIL — bus returned ZERO bytes (rc=${rc:-0});"
    err "this is almost always the luna-send STDIN trap, not a broken TV."
    err "See docs/VERIFICATION-REPORT.md §0.1 for the reproduction matrix."
    exit 1
}
usage() {
    cat <<EOF
notify.sh — send a native webOS toast to the TV.

  scripts/notify.sh -m "hello"                  send a toast
  scripts/notify.sh -m "hello" -t 5             auto-close after N s
  scripts/notify.sh -m "tick" -r 3 -g 2         repeat 3x, 2 s apart
  scripts/notify.sh -c TOASTID                  close a specific toast
  scripts/notify.sh -C                          close the last toast this script sent
  scripts/notify.sh --selftest                  bus reachability tripwire
  scripts/notify.sh -h                          this help

Flags:
  -m MESSAGE       toast body (required unless -c/-C/--selftest/-h)
  -t SECONDS       remember toastId and closeToast after N s
  -i ICONURL       icon URL (passed through to the bus)
  -s SOURCEID      sourceId (default: $DEFAULT_SOURCE_ID)
  -a APPID         passed through as \`luna-send -a <APPID>\`
  -r N             repeat N times (default: 1)
  -g SECONDS       gap between repeats (default: 1)
  -c TOASTID       close a specific toastId and exit
  -C               close the last toast this script sent and exit
  --selftest       call getServiceAPIVersions; FAIL with matrix hint on 0 bytes
  -h, --help       this help and exit

Env (remote mode): TV_HOST=<host>, TV_USER=root (default), TV_PORT=22 (default).
LOCAL mode (luna-send in PATH) AND TV_HOST set together is an error.
Exit: 0 ok / 1 usage / 2 missing TV_HOST / 3 ssh / 4 bus reply not returnValue:true.
EOF
}

main() {
    message=""; timeout=""; icon=""; source_id="$DEFAULT_SOURCE_ID"
    appid=""; repeat=1; gap=1
    close_id=""; close_last=0; selftest=0

    while [ $# -gt 0 ]; do case "$1" in
        -m) message=${2:-}; shift 2 ;; -t) timeout=${2:-}; shift 2 ;;
        -i) icon=${2:-}; shift 2 ;; -s) source_id=${2:-}; shift 2 ;;
        -a) appid=${2:-}; shift 2 ;; -r) repeat=${2:-}; shift 2 ;;
        -g) gap=${2:-}; shift 2 ;; -c) close_id=${2:-}; shift 2 ;;
        -C) close_last=1; shift ;; --selftest) selftest=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) err "unknown argument: $1"; usage >&2; exit 1 ;;
    esac; done

    LOCAL_MODE=0
    if have luna-send; then
        LOCAL_MODE=1
        if [ -n "${TV_HOST:-}" ]; then
            err "TV_HOST is set but luna-send is in PATH — refusing to mix modes"
            err "  unset TV_HOST to run locally, or drop luna-send from PATH to drive via ssh"
            exit 1
        fi
    elif [ -z "${TV_HOST:-}" ]; then
        err "luna-send is not in PATH and TV_HOST is not set"
        err "  on-device: this script needs /usr/bin/luna-send"
        err "  off-device: set TV_HOST to your ssh alias (e.g. TV_HOST=lgtv)"
        exit 2
    fi

    [ "$selftest" = "1" ] && do_selftest

    if [ "$close_last" = "1" ]; then
        if [ -n "$close_id" ]; then
            err "-C and -c are mutually exclusive"; exit 1
        fi
        close_id=$(read_remembered)
        [ -n "$close_id" ] || { err "no last toast remembered (state file empty)"; exit 1; }
    fi
    if [ -n "$close_id" ]; then
        send 'luna://com.webos.notification/closeToast' \
            "$(printf '{"toastId":"%s"}' "$(json_escape "$close_id")")" >/dev/null
        log "close OK: $close_id"; exit 0
    fi

    if [ -z "$message" ]; then
        err "missing -m MESSAGE (required unless -c / -C / --selftest / -h)"
        usage >&2; exit 1
    fi

    case "$repeat"  in ''|*[!0-9]*|0) err "-r must be a positive integer"; exit 1 ;; esac
    case "$gap"     in ''|*[!0-9]*)  err "-g must be a non-negative integer"; exit 1 ;; esac
    case "$timeout" in ''|*[!0-9]*|0) [ -n "$timeout" ] && { err "-t must be a positive integer"; exit 1; } ;; esac
    [ "$LOCAL_MODE" = "0" ] && ! probe_ssh && exit 3

    msg_j=$(json_escape "$message")
    src_j=$(json_escape "$source_id")
    if [ -n "$icon" ]; then
        icon_j=$(json_escape "$icon")
        payload=$(printf '{"message":"%s","sourceId":"%s","iconUrl":"%s"}' "$msg_j" "$src_j" "$icon_j")
    else
        payload=$(printf '{"message":"%s","sourceId":"%s"}' "$msg_j" "$src_j")
    fi

    last_toast_id=""; i=0
    while [ "$i" -lt "$repeat" ]; do
        reply=$(send 'luna://com.webos.notification/createToast' "$payload" "$appid")
        last_toast_id=$(printf '%s' "$reply" \
            | sed -n 's/.*"toastId" *: *"\([^"]*\)".*/\1/p')
        [ "$repeat" -gt 1 ] && log "posted $((i + 1))/$repeat: $message (toastId=$last_toast_id)"
        i=$((i + 1))
        [ "$i" -lt "$repeat" ] && sleep "$gap"
    done

    last_toast_id=${last_toast_id:-<none>}
    if [ "$repeat" -eq 1 ]; then
        log "posted: $message (toastId=$last_toast_id)"
    else
        log "posted $repeat toasts; last toastId=$last_toast_id"
    fi
    [ -n "$last_toast_id" ] && write_remembered "$last_toast_id"
    if [ -n "$timeout" ] && [ -n "$last_toast_id" ]; then
        cp=$(printf '{"toastId":"%s"}' "$(json_escape "$last_toast_id")")
        ( sleep "$timeout"; luna 'luna://com.webos.notification/closeToast' \
            "$cp" >/dev/null 2>&1 || true ) &
        log "will auto-close in ${timeout}s"
    fi
}
main "$@"
