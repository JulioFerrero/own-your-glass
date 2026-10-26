# tests/upstart.sh — a fake upstart (initctl 1.10) answering like webOS 4.
#
#   upstart_job <job> running|waiting [start-on]   add a job
#   upstart_stub                                   put initctl on PATH
#
# Job state lives in $T_TMP/jobs/<job>: line 1 is the goal/state, line 2 the
# "start on" condition (empty: started by hand only).

upstart_job() {
    mkdir -p "$T_TMP/jobs"
    case $2 in
        running) printf 'start/running, process 100\n%s\n' "${3:-}" ;;
        *) printf 'stop/waiting\n%s\n' "${3:-}" ;;
    esac >"$T_TMP/jobs/$1"
}

upstart_stub() {
    # shellcheck disable=SC2016 # expanded by the stub
    stub initctl '
f="$T_TMP/jobs/$2"
[ -f "$f" ] || { echo "initctl: Unknown job: $2" >&2; exit 1; }
on=$(sed -n 2p "$f")
case $1 in
    status) echo "$2 $(head -n 1 "$f")" ;;
    show-config) echo "$2"; [ -z "$on" ] || echo "  start on $on" ;;
    stop)
        grep -q "^start/" "$f" || { echo "initctl: Unknown instance: " >&2; exit 1; }
        printf "stop/waiting\n%s\n" "$on" >"$f"; echo "$2 stop/waiting" ;;
    start)
        grep -q "^stop/" "$f" || { echo "initctl: Job is already running: $2" >&2; exit 1; }
        printf "start/running, process 200\n%s\n" "$on" >"$f"; echo "$2 start/running, process 200" ;;
esac'
}
