#!/bin/sh
# notify.sh — send a native webOS toast to the TV.
#
# Works both ON the TV (uses local luna-send) and FROM the computer
# (uses ssh + TV_HOST/TV_USER/TV_PORT). Used by `oyg list`/operators
# to push status toasts, and as the tripwire for the luna-send/LS2
# stdin trap (see --selftest).
#
# =====================================================================
# !!!  L U N A - S E N D   S T D I N   T R A P   !!!
# =====================================================================
# webOS's `luna-send` reads its JSON payload from ARGUMENTS, but it
# also reads its reply from a pipe, and that pipe reads from STDIN
# once the request has been sent. If STDIN is open and connected
# (e.g. inherited from a `sh -s` heredoc, an interactive shell, or
# a piped parent), the pipe gets EOF BEFORE the reply arrives, and
# luna-send exits with rc=0 and ZERO bytes on stdout/stderr — the
# call appears to succeed and the reply never appears.
#
# The original investigation interpreted this as "luna-send is broken
# on the TV / LS2 is unreachable". It was not. LS2 was reachable the
# whole time. Every `luna-send` invocation in this script ENDS with
# `</dev/null` for that reason — DO NOT remove them, and DO NOT
# capture luna-send output with `$( )` unless the `</dev/null` is
# also present. This bug cost two false findings (luna-send broken;
# LS2 unreachable) the first time around.
#
# Reproduced matrix (verbatim, with `</dev/null` column A=WORKS):
#
#   A $(...) + stdin=/dev/null      bytes=108
#   B $(...) + stdin=inherited      bytes=0     ← the broken case
#   C pipe|cat + stdin=/dev/null    bytes=109
#   D >file + stdin=inherited       bytes=0
#   E no -i >file + inherited       bytes=0
#
# Only the STDIN dimension matters. Add `</dev/null` and everything
# works. Use --selftest to verify on first run of a session.
# =====================================================================
#
# Usage:
#   scripts/notify.sh -m "hello"                    # from your computer
#   scripts/notify.sh -m "hello" -t 5 -i http://…   # auto-close after 5s
#   scripts/notify.sh -r 3 -g 2 -m "tick"           # 3 toasts, 2s apart
#   scripts/notify.sh -C                            # close the last one sent
#   scripts/notify.sh -c "com.webos.surfacemanager-…"
#   scripts/notify.sh --selftest                    # bus reachability tripwire
#   scripts/notify.sh -h                            # this help
#
# Environment:
#   TV_HOST=<ip|hostname>     target TV (REQUIRED in remote mode)
#   TV_USER=root              SSH user on the TV (default: root)
#   TV_PORT=22                SSH port (default: 22)
#
# When `luna-send` is in PATH the script runs locally on the TV
# (the typical case for an operator who has SSHed in); otherwise it
# drives `luna-send` over ssh. Reject the two being mixed: if
# TV_HOST is set AND luna-send is on PATH, error out — the operator
# almost certainly got one of them wrong.

set -eu

OYG_HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

TV_USER=${TV_USER:-root}
TV_PORT=${TV_PORT:-22}

# State file for `-C` (close the last toast this script sent).
# On-device: /var/lib/own-your-glass/notify.last. (NOT under state/:
# oyg uses state as a flat KEY=VALUE file, not a directory — sibling
# keeps both writable without us having to mkdir.)
# Off-device: a mktemp file under TMPDIR.
NOTIFY_STATE_PATH="/var/lib/own-your-glass/notify.last"

# Default notification sourceId. Surfaced as `-s`.
DEFAULT_SOURCE_ID="com.webos.surfacemanager"

have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '[notify] %s\n' "$*"; }
warn() { printf '[notify] WARN %s\n' "$*" >&2; }
err()  { printf '[notify] ERR  %s\n' "$*" >&2; }

# json_escape <string>
#   Escape a string for inclusion as a JSON string value (the value
#   side, NOT the wrapping). Escapes backslash and double-quote only;
#   control chars are left alone (the TV's bus accepts them in toasts).
#   We do NOT need to escape / or unicode here — webOS toast messages
#   are human text and `/` is harmless.
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# sh_quote_sed <string>
#   Single-quote-escape <string> for embedding in a remote shell
#   single-quoted argument. POSIX `sh -c '...'` has no nested quoting,
#   so we close the quote, emit an escaped single quote, and reopen.
sh_quote_sed() {
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

usage() {
    cat <<EOF
notify.sh — send a native webOS toast to the TV.

Usage:
  scripts/notify.sh -m "hello"                  send a toast
  scripts/notify.sh -m "hello" -t 5             auto-close after 5s
  scripts/notify.sh -m "tick" -r 3 -g 2         repeat 3x, 2s apart
  scripts/notify.sh -c "toastId"                close a specific toast
  scripts/notify.sh -C                          close the last toast this script sent
  scripts/notify.sh --selftest                  bus reachability tripwire
  scripts/notify.sh -h                          this help

Required:
  -m MESSAGE                toast body (must be set unless -c/-C/--selftest/-h)

Optional:
  -t SECONDS                remember toastId and closeToast after N s
  -i ICONURL                icon URL (passed through to the bus)
  -s SOURCEID               sourceId (default: $DEFAULT_SOURCE_ID)
  -a APPID                  passed through as \`luna-send -a <APPID>\`
                            (default: none — \`createToast\` works
                            without an appId on this firmware)
  -r N                      repeat N times (default: 1)
  -g SECONDS                gap between repeats in seconds (default: 1)
  -c TOASTID                close a specific toastId and exit
  -C                        close the last toast this script sent and exit
  --selftest                call \`getServiceAPIVersions\` and report
                            OK if the bus is reachable, FAIL with the
                            stdin/EOF hint and reproduction matrix
                            otherwise. This is the tripwire that
                            would have caught the original mistake.
  -h, --help                this help and exit

Environment:
  TV_HOST=<ip|hostname>     target TV (required in remote mode; the
                            script auto-detects mode by whether
                            \`luna-send\` is in PATH)
  TV_USER=root              SSH user on the TV (default: root)
  TV_PORT=22                SSH port on the TV (default: 22)

Exit codes:
  0  success (toast posted, toast closed, or selftest OK)
  1  usage / argument error (missing -m, both -c/-C, etc.)
  2  TV_HOST missing in remote mode
  3  ssh / transport failure
  4  bus returned a reply without \`returnValue:true\` (the toast
     may still have posted — raw reply is printed to stderr)

NOTE — the luna-send stdin trap:
  Every \`luna-send\` call in this script ends with \`</dev/null\`.
  Do not capture \`luna-send\` output with \`\$( )\` unless that
  stdin redirect is also present. \`luna-send\` exits with rc=0
  and ZERO bytes on stdout/stderr if its stdin is closed by the
  parent shell before the reply arrives (e.g. \`sh -s\` heredocs,
  interactive shells, or any piped parent). The reply IS on the
  bus; you just lost it. See the header comment for the matrix.

EOF
}

# state_path_on_local
#   Path of the local "last toast" file. On-device uses
#   /var/lib/own-your-glass/notify.last; off-device uses TMPDIR.
#   We test whether the file is writable (or its parent dir is) —
#   on-device root can write it; off-device we cannot.
state_path_on_local() {
    if [ -w "$NOTIFY_STATE_PATH" ] 2>/dev/null \
        || [ -w "$(dirname -- "$NOTIFY_STATE_PATH")" ] 2>/dev/null; then
        printf '%s\n' "$NOTIFY_STATE_PATH"
    else
        mktemp -t notify.last.XXXXXX 2>/dev/null \
            || printf '%s/notify.last.%s' "${TMPDIR:-/tmp}" "$$"
    fi
}

# state_path_remote_cmd
#   Echoes the device-side state path (literal, not a subshell).
state_path_remote_cmd() {
    printf '%s\n' "$NOTIFY_STATE_PATH"
}

# run_luna_local <json-payload> [appid-arg]
#   Run `luna-send` LOCALLY (we ARE on the TV) with the magic stdin
#   redirect that makes the bus reply actually reach us. Replies go
#   to stdout; callers must NOT pipe this into $( ) (the matrix in
#   the header comment shows B is the broken case). Use case-by-case
#   inspection of the reply instead.
run_luna_local() {
    payload=$1
    appid_arg=${2:-}
    # `</dev/null` is load-bearing — see header comment.
    # shellcheck disable=SC2086
    if [ -n "$appid_arg" ]; then
        luna-send -i -n 1 -f \
            luna://com.webos.notification/createToast \
            -a "$appid_arg" \
            "$payload" </dev/null
    else
        luna-send -i -n 1 -f \
            luna://com.webos.notification/createToast \
            "$payload" </dev/null
    fi
}

# run_luna_local_close <json-payload>
run_luna_local_close() {
    payload=$1
    luna-send -i -n 1 -f \
        luna://com.webos.notification/closeToast \
        "$payload" </dev/null
}

# run_luna_ssh <ssh_user> <ssh_host> <ssh_port> <json-payload> [appid-arg]
#   Run `luna-send` over ssh with the magic stdin redirect. Echoes
#   the reply on stdout. The `</dev/null` is on the REMOTE side: it
#   is the TV's stdin that gets closed, not ours.
run_luna_ssh() {
    user=$1
    host=$2
    port=$3
    payload=$4
    appid_arg=${5:-}
    if [ -n "$appid_arg" ]; then
        # shellcheck disable=SC2086
        ssh -o BatchMode=yes \
            -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=accept-new \
            -p "$port" \
            "$user@$host" \
            "luna-send -i -n 1 -f luna://com.webos.notification/createToast -a '$appid_arg' '$payload' </dev/null"
    else
        ssh -o BatchMode=yes \
            -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=accept-new \
            -p "$port" \
            "$user@$host" \
            "luna-send -i -n 1 -f luna://com.webos.notification/createToast '$payload' </dev/null"
    fi
}

# run_luna_ssh_close <ssh_user> <ssh_host> <ssh_port> <json-payload>
run_luna_ssh_close() {
    user=$1
    host=$2
    port=$3
    payload=$4
    ssh -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        -p "$port" \
        "$user@$host" \
        "luna-send -i -n 1 -f luna://com.webos.notification/closeToast '$payload' </dev/null"
}

# probe_ssh <user> <host> <port>
#   Strict, non-interactive ssh probe; refused password prompt is a
#   failure (root should be key-authenticated at this point).
probe_ssh() {
    user=$1
    host=$2
    port=$3
    if ssh -o BatchMode=yes \
           -o ConnectTimeout=5 \
           -o StrictHostKeyChecking=accept-new \
           -p "$port" \
           "$user@$host" 'echo OYG_NOTIFY_OK' >/dev/null 2>&1; then
        return 0
    fi
    err "host $host unreachable or auth failed for $user"
    err "  - is the TV on and reachable from this machine?"
    err "  - did you ssh-copy-id your key (see README 'Rooting your TV')?"
    err "  - try: ssh $user@$host  (to see what the device says)"
    return 1
}

# selftest_hint — the loud "you hit the stdin trap" message.
selftest_hint() {
    cat >&2 <<'EOF'

[notify] --selftest FAIL: the bus did not reply.

  This is almost always the luna-send STDIN trap, not a broken TV.

  webOS's `luna-send` reads the reply on a pipe that's connected to
  STDIN. If STDIN is closed (EOF) BEFORE the reply arrives, the
  process exits with rc=0 and zero bytes on stdout/stderr. The call
  looks like it silently succeeded — which is exactly the bug that
  produced two false findings ("luna-send broken", "LS2 unreachable")
  in the original investigation.

  Reproduced matrix (verbatim):
    A $( )    + stdin=/dev/null      bytes=108   ← the FIX
    B $( )    + stdin=inherited      bytes=0     ← the BUG
    C pipe|cat + stdin=/dev/null     bytes=109
    D >file    + stdin=inherited     bytes=0
    E no -i >file + inherited        bytes=0

  Only the STDIN dimension matters. The fix is one byte:

    luna-send -i -n 1 -f luna://com.webos.notification/createToast \
        '{"message":"…","sourceId":"com.webos.surfacemanager"}' \
        </dev/null                                  ← required

  See the header of scripts/notify.sh for the full story.
EOF
}

main() {
    # ----- arg parse -----------------------------------------------------
    message=""
    timeout=""
    icon=""
    source_id="$DEFAULT_SOURCE_ID"
    appid=""
    repeat=1
    gap=1
    close_id=""
    close_last=0
    selftest=0

    while [ $# -gt 0 ]; do
        case "$1" in
            -m) message=${2:-}; shift 2 ;;
            -t) timeout=${2:-}; shift 2 ;;
            -i) icon=${2:-}; shift 2 ;;
            -s) source_id=${2:-}; shift 2 ;;
            -a) appid=${2:-}; shift 2 ;;
            -r) repeat=${2:-}; shift 2 ;;
            -g) gap=${2:-}; shift 2 ;;
            -c) close_id=${2:-}; shift 2 ;;
            -C) close_last=1; shift ;;
            --selftest) selftest=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *)
                err "unknown argument: $1"
                usage >&2
                exit 1
                ;;
        esac
    done

    # ----- mode detection ----------------------------------------------
    # LOCAL  = luna-send is in PATH  (we are ON the TV, or a container
    #          that happens to ship the same userland)
    # REMOTE = luna-send is NOT in PATH  (we are off the TV)
    # Refuse the mixed case — TV_HOST set AND luna-send present means
    # the operator almost certainly got one of them wrong.
    local_mode=0
    if have luna-send; then
        local_mode=1
        if [ -n "${TV_HOST:-}" ]; then
            err "TV_HOST is set but luna-send is in PATH — refusing to mix modes."
            err "  unset TV_HOST to run locally (typical: you are on the TV),"
            err "  or run from a shell that does NOT have luna-send to drive the TV over ssh."
            exit 1
        fi
    else
        if [ -z "${TV_HOST:-}" ]; then
            err "luna-send is not in PATH and TV_HOST is not set."
            err "  - on the TV: this script needs /usr/bin/luna-send (it ships in /usr/bin)."
            err "  - off the TV: set TV_HOST to your ssh alias (e.g. TV_HOST=lgtv)."
            exit 2
        fi
    fi

    # ----- selftest -----------------------------------------------------
    if [ "$selftest" = "1" ]; then
        # The tripwire: did the bus reply at all? Any non-empty reply
        # proves the bus is reachable and luna-send is functional; an
        # empty reply is the STDIN trap. Note: we DO NOT depend on
        # returnValue:true here because the strict LS2 on this firmware
        # may reject the synthetic version payload with a schema error
        # even though the call reached the bus. The point is that the
        # reply made it back to us at all.
        selftest_payload='{"serviceName":"com.webos.notification"}'
        if [ "$local_mode" = "1" ]; then
            reply=$(luna-send -i -n 1 -f \
                luna://com.webos.service.bus/getServiceAPIVersions \
                "$selftest_payload" </dev/null) || rc=$?
            rc=${rc:-0}
        else
            if ! probe_ssh "$TV_USER" "$TV_HOST" "$TV_PORT"; then
                exit 3
            fi
            reply=$(ssh -o BatchMode=yes \
                -o ConnectTimeout=5 \
                -o StrictHostKeyChecking=accept-new \
                -p "$TV_PORT" \
                "$TV_USER@$TV_HOST" \
                "luna-send -i -n 1 -f luna://com.webos.service.bus/getServiceAPIVersions '$selftest_payload' </dev/null") || rc=$?
            rc=${rc:-0}
        fi
        if [ -n "$reply" ]; then
            log "selftest OK — bus replied ($(printf '%s' "$reply" | wc -c | tr -d ' ') bytes)"
            if printf '%s' "$reply" | grep -q '"returnValue": *true' 2>/dev/null; then
                log "  reply: $reply"
                exit 0
            fi
            # Reply is non-empty but does not declare returnValue:true.
            # That is still OK for the tripwire — the bus is reachable,
            # the stdin trap is not biting. Surface the reply so the
            # operator can see whether the schema was rejected.
            log "  reply (bus reachable; schema may have rejected synthetic payload): $reply"
            exit 0
        fi
        # Empty reply: the stdin trap bit. Loud failure.
        err "selftest FAIL — bus returned ZERO bytes (rc=$rc)."
        selftest_hint
        exit 1
    fi

    # ----- close-only paths --------------------------------------------
    if [ "$close_last" = "1" ] && [ -n "$close_id" ]; then
        err "-C and -c are mutually exclusive"
        exit 1
    fi
    if [ "$close_last" = "1" ]; then
        if [ "$local_mode" = "1" ]; then
            state_path=$(state_path_on_local)
            close_id=$(cat "$state_path" 2>/dev/null || true)
        else
            close_id=$(ssh -o BatchMode=yes \
                -o ConnectTimeout=5 \
                -o StrictHostKeyChecking=accept-new \
                -p "$TV_PORT" \
                "$TV_USER@$TV_HOST" \
                "cat $(state_path_remote_cmd) 2>/dev/null || true")
        fi
        if [ -z "$close_id" ]; then
            err "no last toast remembered (state file empty)"
            exit 1
        fi
        # fall through to the close-by-id path
    fi

    if [ -n "$close_id" ]; then
        # Validate it looks like a toastId. createToast returns IDs of
        # the form "<sourceId>-<digits>". We accept anything non-empty
        # because the bus will reject malformed IDs cleanly.
        close_payload=$(printf '{"toastId":"%s"}' "$(json_escape "$close_id")")
        if [ "$local_mode" = "1" ]; then
            reply=$(run_luna_local_close "$close_payload") || rc=$?
            rc=${rc:-0}
        else
            reply=$(run_luna_ssh_close "$TV_USER" "$TV_HOST" "$TV_PORT" "$close_payload") || rc=$?
            rc=${rc:-0}
        fi
        if printf '%s' "$reply" | grep -q '"returnValue": *true' 2>/dev/null; then
            log "close OK: $close_id"
            exit 0
        fi
        err "close failed (rc=$rc): $reply"
        exit 4
    fi

    # ----- send path ---------------------------------------------------
    if [ -z "$message" ]; then
        err "missing -m MESSAGE (required unless -c / -C / --selftest / -h)"
        usage >&2
        exit 1
    fi

    # Validate numeric args early so the bus doesn't see garbage.
    case "$repeat" in ''|*[!0-9]*)
        err "-r must be a positive integer"; exit 1 ;;
    esac
    if [ "$repeat" -lt 1 ]; then
        err "-r must be >= 1"; exit 1
    fi
    case "$gap" in ''|*[!0-9]*)
        err "-g must be a non-negative integer"; exit 1 ;;
    esac
    if [ -n "$timeout" ]; then
        case "$timeout" in ''|*[!0-9]*)
            err "-t must be a positive integer (seconds)"; exit 1 ;;
        esac
        if [ "$timeout" -lt 1 ]; then
            err "-t must be >= 1"; exit 1
        fi
    fi

    if [ "$local_mode" = "0" ] && ! probe_ssh "$TV_USER" "$TV_HOST" "$TV_PORT"; then
        exit 3
    fi

    last_toast_id=""
    i=0
    while [ "$i" -lt "$repeat" ]; do
        # Build the JSON payload. We assemble the keys with `printf`
        # so we can keep the message value as a JSON-escaped string
        # without spawning a second process.
        msg_j=$(json_escape "$message")
        src_j=$(json_escape "$source_id")
        if [ -n "$icon" ]; then
            icon_j=$(json_escape "$icon")
            payload=$(printf '{"message":"%s","sourceId":"%s","iconUrl":"%s"}' \
                "$msg_j" "$src_j" "$icon_j")
        else
            payload=$(printf '{"message":"%s","sourceId":"%s"}' \
                "$msg_j" "$src_j")
        fi

        if [ "$local_mode" = "1" ]; then
            reply=$(run_luna_local "$payload" "$appid") || rc=$?
            rc=${rc:-0}
        else
            # Remote: the remote side already has the payload as a
            # SINGLE-QUOTED shell argument. We need to single-quote-
            # escape the JSON we just built so the remote shell can
            # consume it. The payload itself contains no single quotes
            # (json_escape only escapes \\ and ") so this is safe.
            remote_payload=$(sh_quote_sed "$payload")
            reply=$(run_luna_ssh "$TV_USER" "$TV_HOST" "$TV_PORT" "$remote_payload" "$appid") || rc=$?
            rc=${rc:-0}
        fi

        if ! printf '%s' "$reply" | grep -q '"returnValue": *true' 2>/dev/null; then
            err "luna-send did not return success (rc=$rc)"
            err "  raw reply: $reply"
            err "  this is the stdin trap if the reply is empty — see scripts/notify.sh header"
            exit 4
        fi

        # Extract the toastId. The reply is on one line and looks like:
        #   { "returnValue": true, "toastId": "com.webos.surfacemanager-1789…" }
        this_toast_id=$(printf '%s' "$reply" \
            | sed -n 's/.*"toastId" *: *"\([^"]*\)".*/\1/p')
        last_toast_id=$this_toast_id
        if [ "$repeat" -gt 1 ]; then
            log "posted $((i + 1))/$repeat: $message (toastId=$this_toast_id)"
        fi

        i=$((i + 1))
        if [ "$i" -lt "$repeat" ]; then
            sleep "$gap"
        fi
    done

    if [ "$repeat" -eq 1 ]; then
        log "posted: $message (toastId=${last_toast_id:-<none>})"
    else
        log "posted $repeat toasts; last toastId=${last_toast_id:-<none>}"
    fi

    # Persist the last toastId so `-C` works. On-device uses
    # /var/lib/own-your-glass/state/notify.last; off-device uses the
    # path we derived above. Either way, remember the latest.
    if [ -n "$last_toast_id" ]; then
        if [ "$local_mode" = "1" ]; then
            state_path=$(state_path_on_local)
        else
            state_path=$(state_path_remote_cmd)
        fi
        if [ "$local_mode" = "1" ]; then
            printf '%s\n' "$last_toast_id" > "$state_path" 2>/dev/null || \
                warn "could not write $state_path (non-fatal)"
        else
            ssh -o BatchMode=yes \
                -o ConnectTimeout=5 \
                -o StrictHostKeyChecking=accept-new \
                -p "$TV_PORT" \
                "$TV_USER@$TV_HOST" \
                "printf '%s\n' '$last_toast_id' > '$state_path' 2>/dev/null" >/dev/null 2>&1 || \
                warn "could not write $state_path on TV (non-fatal)"
        fi
    fi

    # Optional auto-close after -t seconds. Done in the background so
    # the caller gets their exit immediately.
    if [ -n "$timeout" ] && [ -n "$last_toast_id" ]; then
        close_payload=$(printf '{"toastId":"%s"}' "$(json_escape "$last_toast_id")")
        if [ "$local_mode" = "1" ]; then
            ( sleep "$timeout"; run_luna_local_close "$close_payload" >/dev/null 2>&1 || true ) &
        else
            remote_payload=$(sh_quote_sed "$close_payload")
            ( sleep "$timeout"; run_luna_ssh_close "$TV_USER" "$TV_HOST" "$TV_PORT" "$remote_payload" >/dev/null 2>&1 || true ) &
        fi
        log "will auto-close in ${timeout}s"
    fi
}

main "$@"