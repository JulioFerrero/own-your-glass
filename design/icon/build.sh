#!/bin/sh
# build.sh — render the app icon and write app/icon.png (80x80),
# app/largeIcon.png (130x130) and the README logo docs/images/logo.png
# (512x512, rounded corners). Needs node, Google Chrome and ImageMagick.
#
# Usage: design/icon/build.sh [query]    default query: variant=crimson
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP=$(CDPATH= cd -- "$HERE/../../app" && pwd)
IMAGES=$(CDPATH= cd -- "$HERE/../../docs" && pwd)/images
mkdir -p "$IMAGES"

[ -d "$HERE/node_modules/three" ] || (cd "$HERE" && npm install --no-audit --no-fund)

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

node "$HERE/render.mjs" "$OUT/master.png@${1:-variant=crimson}"
# Downscale the 2048 master; a light unsharp keeps the bevels crisp at TV size.
magick "$OUT/master.png" -filter Lanczos -resize 130x130 -unsharp 0x0.6+0.5+0 -alpha off -strip "$APP/largeIcon.png"
magick "$OUT/master.png" -filter Lanczos -resize 80x80 -unsharp 0x0.6+0.6+0 -alpha off -strip "$APP/icon.png"
magick "$OUT/master.png" -filter Lanczos -resize 512x512 \
    \( -size 512x512 xc:none -draw "roundrectangle 0,0 511,511 92,92" \) \
    -compose DstIn -composite -strip "$IMAGES/logo.png"
echo "wrote $APP/largeIcon.png (130), $APP/icon.png (80) and $IMAGES/logo.png (512)"
