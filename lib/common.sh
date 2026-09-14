OYG_LIB=1

OYG_ROOT=${OYG_ROOT:-/var/lib/own-your-glass}
OYG_STATE="$OYG_ROOT/state"
OYG_BACKUP="$OYG_ROOT/backup"
OYG_LOG="$OYG_ROOT/log.txt"
OYG_WATCHERS="$OYG_ROOT/watchers"
OYG_DRY_RUN=${OYG_DRY_RUN:-0}

umask 077

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
ok()   { printf '[%s] OK   %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; }
err()  { printf '[%s] ERR  %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; }

have() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {
    if [ "$(id -u 2>/dev/null)" != "0" ] && [ "$OYG_DRY_RUN" != "1" ]; then
        err "must be run as root (or use --dry-run)"
        exit 1
    fi
}

ensure_dirs() {
    [ "$OYG_DRY_RUN" = "1" ] && return 0
    [ -d "$OYG_ROOT" ] && return 0
    if mkdir -p "$OYG_ROOT" "$OYG_BACKUP" "$OYG_WATCHERS" 2>/dev/null; then
        return 0
    fi
    err "cannot create $OYG_ROOT — are you root, or is /var/lib writable here?"
    return 1
}

run() {
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: %s\n' "$*"
        return 0
    fi
    if [ -n "${OYG_LOG:-}" ]; then
        printf '[%s] RUN   %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$OYG_LOG" 2>/dev/null || true
    fi
    "$@"
}

_run_capture() {
    if [ "$OYG_DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: %s\n' "$*"
        return 0
    fi
    if [ -n "${OYG_LOG:-}" ]; then
        printf '[%s] RUN   %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$OYG_LOG" 2>/dev/null || true
    fi
    "$@"
}

backup_path() {
    src=$1
    [ -z "$src" ] && return 1
    if [ ! -e "$src" ] && [ ! -L "$src" ]; then
        return 1
    fi
    ensure_dirs
    key=$(printf '%s' "$src" | tr '/' '_')
    dest="$OYG_BACKUP/${key}.meta"
    if [ -e "$dest" ]; then
        return 0
    fi
    {
        printf 'PATH=%s\n' "$src"
        if [ -L "$src" ]; then
            printf 'TYPE=symlink\n'
            printf 'TARGET=%s\n' "$(readlink "$src")"
        elif [ -d "$src" ]; then
            printf 'TYPE=dir\n'
        else
            printf 'TYPE=file\n'
        fi
        printf 'MODE=%s\n' "$(stat -c '%a' "$src" 2>/dev/null || stat -f '%Lp' "$src" 2>/dev/null || echo unknown)"
        printf 'OWNER=%s\n' "$(stat -c '%u:%g' "$src" 2>/dev/null || stat -f '%u:%g' "$src" 2>/dev/null || echo unknown)"
    } >"$dest" 2>/dev/null || {
        err "failed to back up $src"
        return 1
    }
    if [ -f "$src" ] && [ ! -L "$src" ]; then
        cp -p "$src" "${dest}.content" 2>/dev/null || true
    fi
    return 0
}

restore_path() {
    src=$1
    [ -z "$src" ] && return 1
    key=$(printf '%s' "$src" | tr '/' '_')
    meta="$OYG_BACKUP/${key}.meta"
    [ ! -e "$meta" ] && return 1
    type=$(awk -F= '/^TYPE=/{print $2}' "$meta")
    mode=$(awk -F= '/^MODE=/{print $2}' "$meta")
    case "$type" in
        file)
            if [ -e "${meta}.content" ]; then
                cp -p "${meta}.content" "$src" 2>/dev/null && chmod "$mode" "$src" 2>/dev/null
            fi
            ;;
        dir)
            [ -d "$src" ] || mkdir -p "$src" 2>/dev/null
            chmod "$mode" "$src" 2>/dev/null || true
            ;;
        symlink)
            target=$(awk -F= '/^TARGET=/{print $2}' "$meta")
            rm -f "$src" 2>/dev/null
            ln -s "$target" "$src" 2>/dev/null
            ;;
    esac
    rm -f "$meta" "${meta}.content" 2>/dev/null
    return 0
}

state_put() {
    key=$1; shift
    [ "$OYG_DRY_RUN" = "1" ] && {
        printf 'DRY-RUN state: %s=%s\n' "$key" "$*"
        return 0
    }
    ensure_dirs
    touch "$OYG_STATE" 2>/dev/null || return 1
    tmp=$(mktemp 2>/dev/null) || return 1
    awk -F= -v k="$key" -v v="$*" '
        $1 == k { found = 1; next }
        { print }
        END { print k "=" v }
    ' "$OYG_STATE" >"$tmp" 2>/dev/null && mv "$tmp" "$OYG_STATE"
    rm -f "$tmp" 2>/dev/null
}

state_get() {
    key=$1
    [ -r "$OYG_STATE" ] || return 1
    awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$OYG_STATE"
}

state_drop() {
    key=$1
    [ "$OYG_DRY_RUN" = "1" ] && return 0
    [ -r "$OYG_STATE" ] || return 0
    tmp=$(mktemp 2>/dev/null) || return 1
    awk -F= -v k="$key" '$1!=k' "$OYG_STATE" >"$tmp" 2>/dev/null && mv "$tmp" "$OYG_STATE"
    rm -f "$tmp" 2>/dev/null
}

state_all() {
    [ -r "$OYG_STATE" ] || return 0
    cat "$OYG_STATE"
}

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

print_status() {
    state=$1; detail=$2
    printf '%-8s %s\n' "$state" "$detail"
}
