#!/bin/sh
# build-app.sh — package app/ into an installable webOS .ipk
#
# An .ipk is an `ar` archive of three members:
#   debian-binary   the literal string "2.0\n"
#   control.tar.gz  package metadata (Package/Version/Architecture/…)
#   data.tar.gz     the payload, rooted at usr/palm/applications/<appId>/
#
# We build it here rather than with ares-cli so the whole toolkit stays
# dependency-free: macOS ships `ar` and `tar`.
#
# Install on the TV with (HBChannel already exposes an installer):
#   luna-send -n 1 -f luna://org.webosbrew.hbchannel.service/install \
#     '{"id":"<appId>","ipkUrl":"http://<host>/<file>.ipk","ipkHash":"<sha256>"}'
#
# Usage: scripts/build-app.sh [app-dir] [out-dir]
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
SRC=${1:-$REPO/app}
DIST=${2:-$REPO/dist}

[ -f "$SRC/appinfo.json" ] || { echo "build-app: no appinfo.json in $SRC" >&2; exit 1; }

json() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$SRC/appinfo.json" | head -1; }
ID=$(json id)
VER=$(json version)
[ -n "$ID" ] || { echo "build-app: appinfo.json has no id" >&2; exit 1; }
[ -n "$VER" ] || VER=0.0.0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# macOS tar injects AppleDouble resource-fork members (._name) unless this is
# set. They would end up inside the installed app directory and confuse the
# webOS app manager.
COPYFILE_DISABLE=1
export COPYFILE_DISABLE

# --- control ---
mkdir -p "$WORK/control"
cat > "$WORK/control/control" <<EOF
Package: $ID
Version: $VER
Architecture: all
Maintainer: own-your-glass
Description: own-your-glass control panel
EOF
( cd "$WORK/control" && tar czf "$WORK/control.tar.gz" ./control )

# --- data ---
PAYLOAD="$WORK/data/usr/palm/applications/$ID"
mkdir -p "$PAYLOAD"
cp -R "$SRC"/. "$PAYLOAD"/
( cd "$WORK/data" && tar czf "$WORK/data.tar.gz" . )

printf '2.0\n' > "$WORK/debian-binary"

# --- ar ---
# NOTE: macOS /usr/bin/ar CANNOT build an ipk. BSD ar treats the archive as a
# Mach-O static library: it injects a `__.SYMDEF SORTED` member and the real
# members become unreadable ("not a mach-o file"). So we write the ar container
# ourselves — the format is a header plus per-member 60-byte headers.
mkdir -p "$DIST"
OUT="$DIST/$ID-$VER.ipk"
rm -f "$OUT"

python3 - "$OUT" "$WORK/debian-binary" "$WORK/control.tar.gz" "$WORK/data.tar.gz" <<'PYEOF'
import os, sys
out, members = sys.argv[1], sys.argv[2:]
with open(out, "wb") as fh:
    fh.write(b"!<arch>\n")
    for path in members:
        data = open(path, "rb").read()
        name = os.path.basename(path)
        if len(name) > 15:
            raise SystemExit("app: member name too long for ar: %s" % name)
        hdr = (name + "/").ljust(16)          # GNU-style name terminator
        hdr += "0".ljust(12)                  # mtime
        hdr += "0".ljust(6)                   # uid
        hdr += "0".ljust(6)                   # gid
        hdr += "100644".ljust(8)              # mode
        hdr += str(len(data)).ljust(10)       # size
        hdr += "`\n"                          # magic
        fh.write(hdr.encode("ascii"))
        fh.write(data)
        if len(data) % 2:
            fh.write(b"\n")
PYEOF

# verify the container round-trips (macOS ar can't read it, so parse it here)
python3 - "$OUT" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read()
assert data[:8] == b"!<arch>\n", "bad ar magic"
off, names = 8, []
while off + 60 <= len(data):
    hdr = data[off:off + 60]
    name = hdr[0:16].decode().strip().rstrip("/")
    size = int(hdr[48:58].decode().strip())
    names.append((name, size))
    off += 60 + size + (size % 2)
print("members:", ", ".join("%s(%d)" % n for n in names))
PYEOF

echo "built:  $OUT"
echo "size:   $(wc -c < "$OUT" | tr -d ' ') bytes"
echo "sha256: $(shasum -a 256 "$OUT" | awk '{print $1}')"
echo "appId:  $ID"
