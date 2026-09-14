#!/bin/sh
# deploy.sh — push own-your-glass to a rooted webOS TV over SSH.
#
# This is path (B) from the README "Install (on the TV)" section.
# For the one-liner that runs on the TV itself, see the README path (A).
#
# Usage:
#   scripts/deploy.sh                       # uses TV_HOST env var
#   TV_HOST=192.168.1.42 scripts/deploy.sh  # explicit host
#
# Optional env:
#   TV_HOST=<ip|hostname>     target TV (REQUIRED, unless --help / --check)
#   TV_USER=root              SSH user on the TV (default: root)
#   TV_PORT=22                SSH port (default: 22)
#   TV_PATH=/tmp/own-your-glass  destination directory on the TV
#                              (default: /tmp/own-your-glass)
#   OYG_DEPLOY_CHECK=1        only run the reachability probe; do not push
#   OYG_DEPLOY_NO_PROBE=1     skip the reachability probe (not recommended)
#
# Flags:
#   --help    print this help and exit
#   --check   same as OYG_DEPLOY_CHECK=1
#
# Exit codes:
#   0  success (or help printed, or check-only clean)
#   1  missing tool (ssh/scp) or missing TV_HOST
#   2  host unreachable (ssh probe failed)
#   3  scp transfer failed
#   4  install.sh invocation failed on the TV

set -u

OYG_HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$OYG_HERE/.." && pwd)

TV_USER=${TV_USER:-root}
TV_PORT=${TV_PORT:-22}
TV_PATH=${TV_PATH:-/tmp/own-your-glass}
CHECK_ONLY=0

log()  { printf '[deploy] %s\n' "$*"; }
warn() { printf '[deploy] WARN %s\n' "$*" >&2; }
err()  { printf '[deploy] ERR  %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<EOF
deploy.sh — push own-your-glass to a rooted webOS TV over SSH.

Usage:
  scripts/deploy.sh                       # uses \$TV_HOST
  TV_HOST=192.168.1.42 scripts/deploy.sh  # explicit host

Required env:
  TV_HOST=<ip|hostname>     target TV (no default)

Optional env:
  TV_USER=root              SSH user on the TV (default: root)
  TV_PORT=22                SSH port (default: 22)
  TV_PATH=/tmp/own-your-glass  destination directory on the TV
  OYG_DEPLOY_CHECK=1        only probe reachability, do not push
  OYG_DEPLOY_NO_PROBE=1     skip the reachability probe (not recommended)

Flags:
  --help    print this help and exit
  --check   same as OYG_DEPLOY_CHECK=1

This is path (B) from README "Install (on the TV)". For the one-liner
that runs ON the TV (path A), see the README.
EOF
}

# Probe the target with a strict, non-interactive ssh. We use
# BatchMode=yes to refuse any password prompt (a password prompt is
# a failure here — root should be key-authenticated at this point),
# and ConnectTimeout=5 so a dead host fails fast instead of hanging.
probe_host() {
    host=$1
    if [ "${OYG_DEPLOY_NO_PROBE:-0}" = "1" ]; then
        log "reachability probe skipped (OYG_DEPLOY_NO_PROBE=1)"
        return 0
    fi
    log "probing $TV_USER@$host:$TV_PORT (BatchMode=yes, ConnectTimeout=5s)"
    if ssh -o BatchMode=yes \
           -o ConnectTimeout=5 \
           -o StrictHostKeyChecking=accept-new \
           -p "$TV_PORT" \
           "$TV_USER@$host" 'echo OYG_DEPLOY_OK' >/dev/null 2>&1; then
        log "probe OK"
        return 0
    fi
    err "host $host unreachable or auth failed for $TV_USER"
    err "  - is the TV on and reachable from this machine?"
    err "  - did you ssh-copy-id your key (see README 'Rooting your TV')?"
    err "  - is SSH enabled in Homebrew Channel → Settings?"
    err "  - try: ssh $TV_USER@$host  (to see what the device says)"
    return 2
}

main() {
    # Parse a single optional flag — --help or --check. Anything else
    # is passed through to the deploy step (we do not accept other
    # flags because they would silently mask typos).
    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage; exit 0 ;;
            --check)   CHECK_ONLY=1 ;;
            *) err "unknown arg: $arg"; usage; exit 64 ;;
        esac
    done

    if [ -z "${TV_HOST:-}" ]; then
        err "TV_HOST is not set"
        usage
        exit 1
    fi

    have ssh || { err "ssh not found in PATH"; exit 1; }
    have scp || { err "scp not found in PATH"; exit 1; }

    if [ ! -d "$ROOT" ] || [ ! -f "$ROOT/install.sh" ]; then
        err "repo root not found at $ROOT (no install.sh there)"
        exit 1
    fi

    if ! probe_host "$TV_HOST"; then
        exit 2
    fi

    if [ "$CHECK_ONLY" = "1" ]; then
        log "check-only mode (--check): host is reachable, exiting"
        exit 0
    fi

    # Make sure the parent directory exists on the TV. We do not
    # assume mkdir exists; ssh a single command. Failure here is
    # treated as a deploy error rather than silent.
    log "ensuring parent dir $(dirname "$TV_PATH") exists on TV"
    if ! ssh -o BatchMode=yes \
             -o ConnectTimeout=5 \
             -o StrictHostKeyChecking=accept-new \
             -p "$TV_PORT" \
             "$TV_USER@$TV_HOST" "mkdir -p '$(dirname "$TV_PATH")'" >/dev/null 2>&1; then
        err "could not create $(dirname "$TV_PATH") on $TV_HOST"
        exit 2
    fi

    # Remove any previous copy so a re-run does not mix old + new
    # files. The repo is small and idempotent; install.sh is also
    # idempotent, but a clean target is easier to reason about.
    log "removing any previous $TV_PATH on TV"
    ssh -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        -p "$TV_PORT" \
        "$TV_USER@$TV_HOST" "rm -rf '$TV_PATH'" >/dev/null 2>&1 || \
        warn "could not remove previous $TV_PATH (may not exist) — continuing"

    log "copying $ROOT to $TV_USER@$TV_HOST:$TV_PATH"
    if ! scp -o BatchMode=yes \
             -o ConnectTimeout=5 \
             -o StrictHostKeyChecking=accept-new \
             -P "$TV_PORT" \
             -r "$ROOT" "$TV_USER@$TV_HOST:$TV_PATH"; then
        err "scp transfer failed"
        exit 3
    fi
    log "copy OK"

    log "running install.sh on TV"
    if ! ssh -o BatchMode=yes \
             -o ConnectTimeout=10 \
             -o StrictHostKeyChecking=accept-new \
             -p "$TV_PORT" \
             "$TV_USER@$TV_HOST" "sh '$TV_PATH/install.sh'"; then
        err "install.sh failed on $TV_HOST"
        err "  you can re-run manually:"
        err "    ssh $TV_USER@$TV_HOST 'sh $TV_PATH/install.sh'"
        exit 4
    fi

    cat <<EOF

[deploy] done. Next steps (run from your computer):

  ssh $TV_USER@$TV_HOST '/var/lib/own-your-glass/oyg list'
  ssh $TV_USER@$TV_HOST '/var/lib/own-your-glass/oyg harden --dry-run'   # review
  ssh $TV_USER@$TV_HOST '/var/lib/own-your-glass/oyg harden'             # apply the safe set
  ssh $TV_USER@$TV_HOST '/var/lib/own-your-glass/oyg verify'

install.sh only copies files and drops the boot hook — nothing is
hardened until you run \`oyg harden\`.
EOF
}

main "$@"
