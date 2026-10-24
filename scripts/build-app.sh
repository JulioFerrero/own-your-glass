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

# Bundle the toolkit itself: installing the app installs own-your-glass.
# The app's APPLY button runs <appdir>/toolkit/install.sh, so a single app
# install is all an operator needs — no separate scp/ssh step.
TOOLKIT="$PAYLOAD/toolkit"
mkdir -p "$TOOLKIT"
for d in modules scripts lib etc; do
    [ -d "$REPO/$d" ] && cp -R "$REPO/$d" "$TOOLKIT"/
done
for f in oyg install.sh uninstall.sh LICENSE NOTICE README.md; do
    [ -f "$REPO/$f" ] && cp "$REPO/$f" "$TOOLKIT"/
done
find "$TOOLKIT" -name '._*' -delete 2>/dev/null
find "$TOOLKIT" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
echo "bundled toolkit: $(find "$TOOLKIT" -type f | wc -l | tr -d ' ') files"
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

SHA=$(shasum -a 256 "$OUT" | awk '{print $1}')

# --- Homebrew Channel manifest ---
# What the webosbrew app store reads. It is published as a release asset
# under a fixed name (releases/latest/download/<appId>.manifest.json), so the
# store follows new releases without a change on its side; the ipk URL names
# the version, so the hash always matches the file it points at.
REPO_URL=https://github.com/${OYG_REPO:-JulioFerrero/own-your-glass}
python3 - "$SRC/appinfo.json" "$DIST/$ID.manifest.json" "$REPO_URL" "$(basename "$OUT")" "$SHA" <<'PYEOF'
import json, sys
appinfo, out, repo, ipk, sha = sys.argv[1:]
info = json.load(open(appinfo))
manifest = {
    "id": info["id"],
    "version": info["version"],
    "type": info["type"],
    "title": info["title"],
    "appDescription": "Hardens a rooted LG webOS TV: microphones, screen capture, ads, telemetry and ACR.",
    "iconUri": "https://raw.githubusercontent.com/%s/main/app/largeIcon.png" % repo.split("github.com/")[1],
    "sourceUrl": repo,
    "rootRequired": True,
    "ipkUrl": "%s/releases/download/v%s/%s" % (repo, info["version"], ipk),
    "ipkHash": {"sha256": sha},
}
with open(out, "w") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
PYEOF

echo "built:  $OUT"
echo "size:   $(wc -c < "$OUT" | tr -d ' ') bytes"
echo "sha256: $SHA"
echo "appId:  $ID"
echo "manifest: $DIST/$ID.manifest.json"
