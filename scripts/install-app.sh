#!/bin/sh
# install-app.sh — install (or update) the own-your-glass app on this TV.
# Runs ON the TV: it downloads the latest GitHub release through Homebrew
# Channel, checks its sha256, installs it and opens the app. Everything
# else (Apply hardening, Undo, ...) is done from the app with the remote.
#
#   ssh root@<tv-ip> 'curl -fsSL https://raw.githubusercontent.com/JulioFerrero/own-your-glass/main/scripts/install-app.sh | sh'
#
# On a webOS other than 3, 4 and 10+, which the toolkit has never been run
# on (webOS 5-9), Apply hardening refuses. '| OYG_FORCE_UNSUPPORTED=1 sh' turns testing mode on
# (Apply then runs anyway), '| OYG_FORCE_UNSUPPORTED=0 sh' turns it off.
# OYG_MANIFEST_URL=<url> installs from another manifest (a test build).

ID=org.ownyourglass.control
MANIFEST=${OYG_MANIFEST_URL:-https://github.com/JulioFerrero/own-your-glass/releases/latest/download/$ID.manifest.json}

say() { printf '[install-app] %s\n' "$*"; }
die() { say "ERROR: $*"; exit 1; }

[ "$(id -u 2>/dev/null)" = "0" ] || die "run this on the TV as root (ssh root@<tv-ip>)"
type luna-send >/dev/null 2>&1 || die "luna-send not found: this is not a webOS TV"

# Testing mode: the file the toolkit's firmware check accepts (lib/common.sh).
ROOT=/var/lib/own-your-glass
rel=$(sed -n 's/.*"webos_release"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /var/run/nyx/os_info.json 2>/dev/null | head -n 1)
case "${rel%%.*}" in [34]) old=0 ;; [0-9]|'') old=1 ;; *) old=0 ;; esac
case "${OYG_FORCE_UNSUPPORTED:-}" in
    1) if [ "$old" = 1 ]; then
           mkdir -p "$ROOT" && : >"$ROOT/allow-unsupported" \
               && say "testing mode ON: Apply hardening will run on webOS ${rel:-?}, which nobody has tested yet"
       else
           say "webOS $rel is supported: testing mode is not needed"
       fi ;;
    0) rm -f "$ROOT/allow-unsupported" && say "testing mode off" ;;
esac
[ "$old" = 1 ] && [ ! -e "$ROOT/allow-unsupported" ] \
    && say "note: this TV runs webOS ${rel:-?}. Apply hardening runs on webOS 3, 4 and 10 and newer, unless you run this line with OYG_FORCE_UNSUPPORTED=1 (untested)"

fetch() { curl -fsSL "$1" 2>/dev/null || wget -qO- "$1" 2>/dev/null; }
m=$(fetch "$MANIFEST") || die "cannot download $MANIFEST (is the TV online?)"
field() { printf '%s\n' "$m" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1; }
url=$(field ipkUrl)
sha=$(field sha256)
ver=$(field version)
[ -n "$url" ] && [ -n "$sha" ] || die "the release manifest has no ipkUrl or sha256"

say "installing own-your-glass ${ver:-?} (Homebrew Channel downloads and checks it)"
# stdin closed: without it luna-send prints nothing and installs nothing, and
# under 'curl | sh' it would read the rest of this script.
# Homebrew Channel sends a handful of progress replies and then stops, so
# luna-send would sit until its timeout: watch its output and stop it once
# the install says finished.
out=/tmp/oyg-install-app.$$
luna-send -w 180000 -n 100 -f luna://org.webosbrew.hbchannel.service/install \
    "{\"id\":\"$ID\",\"ipkUrl\":\"$url\",\"ipkHash\":\"$sha\",\"subscribe\":true}" </dev/null >"$out" 2>&1 &
lp=$!
n=0
while [ "$n" -lt 180 ] && kill -0 "$lp" 2>/dev/null; do
    grep -q '"finished"[[:space:]]*:[[:space:]]*true\|"errorText"' "$out" 2>/dev/null && break
    sleep 1; n=$((n + 1))
done
kill "$lp" 2>/dev/null
res=$(cat "$out"); rm -f "$out"
printf '%s\n' "$res" | sed -n 's/.*"statusText"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/  \1/p' | uniq
printf '%s\n' "$res" | grep -q '"finished"[[:space:]]*:[[:space:]]*true' \
    && ! printf '%s\n' "$res" | grep -q '"errorText"' \
    || { printf '%s\n' "$res" | grep '"errorText"'; die "the install did not finish (is Homebrew Channel installed?)"; }

# Right after the install the app manager may not know the app yet: retry
# the launch until it is on screen.
n=0
while [ "$n" -lt 10 ]; do
    luna-send -n 1 luna://com.webos.applicationManager/launch "{\"id\":\"$ID\"}" </dev/null >/dev/null 2>&1
    sleep 2
    luna-send -n 1 -f luna://com.webos.applicationManager/getForegroundAppInfo '{}' </dev/null 2>/dev/null \
        | grep -q "\"$ID\"" && { say "done: own-your-glass is open on the TV. Press Apply hardening there."; exit 0; }
    n=$((n + 1))
done
say "installed. Open own-your-glass from the TV's app list and press Apply hardening."
