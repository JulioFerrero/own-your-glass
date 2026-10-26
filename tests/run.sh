#!/bin/sh
# tests/run.sh — run the test suite in whatever shell runs this file.
#
#   sh tests/run.sh                 every tests/test_*.sh
#   sh tests/run.sh tests/test_x.sh one file
#
# Each test_* function in a file runs in its own subshell with a fresh temp
# dir (see tests/lib.sh). Run it in the TV's shell family too:
#   docker run --rm --platform linux/amd64 -v "$PWD":/oyg -w /oyg busybox:1.26 sh tests/run.sh
#   dash tests/run.sh

T_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
OYG_SRC=$(dirname -- "$T_DIR")
export T_DIR OYG_SRC

[ $# -gt 0 ] || set -- "$T_DIR"/test_*.sh

pass=0
skipped=0
fail=0
for f in "$@"; do
    name=$(basename "$f" .sh)
    # function names have no spaces, so word splitting is what we want
    # shellcheck disable=SC2013
    for t in $(sed -n 's/^\(test_[A-Za-z0-9_]*\)[[:space:]]*()[[:space:]]*{.*/\1/p' "$f"); do
        # shellcheck source=/dev/null
        if out=$( (. "$T_DIR/lib.sh" && . "$f" && t_setup && "$t") 2>&1 ); then
            case $out in
                *SKIP:*)
                    skipped=$((skipped + 1))
                    printf 'skip    %s: %s (%s)\n' "$name" "$t" "${out##*SKIP: }" ;;
                *)
                    pass=$((pass + 1))
                    printf 'ok      %s: %s\n' "$name" "$t" ;;
            esac
        else
            fail=$((fail + 1))
            printf 'not ok  %s: %s\n' "$name" "$t"
            printf '%s\n' "$out" | sed 's/^/        /'
        fi
    done
done

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
