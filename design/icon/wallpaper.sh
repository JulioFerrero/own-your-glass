#!/bin/sh
# wallpaper.sh — render the home-screen wallpaper, etc/home-wallpaper.png
# (3492x1450: the hero area of the launcher's wallpaper layout in 4K
# units). The emblem sits on the left of a dark field that fades to black
# at the edges, so it blends into the home's own background. LG's welcome
# line and its button are drawn over the right half, so that side stays
# dark. Needs node, Google Chrome and ImageMagick (same as build.sh).
#
# Usage: design/icon/wallpaper.sh [query]    default query: variant=crimson
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ETC=$(CDPATH= cd -- "$HERE/../../etc" && pwd)

[ -d "$HERE/node_modules/three" ] || (cd "$HERE" && npm install --no-audit --no-fund)

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

node "$HERE/render.mjs" "$OUT/master.png@${1:-variant=crimson}"
# The emblem with its square background feathered away.
magick "$OUT/master.png" -filter Lanczos -resize 940x940 \
    \( -size 940x940 radial-gradient:white-black -level 0%,62% \) \
    -alpha off -compose CopyOpacity -composite "$OUT/emblem.png"
# Dark field, a red glow behind the emblem, a vignette to black, the emblem.
magick -size 3492x1450 xc:'#0a0807' \
    \( -size 2000x2000 radial-gradient:'#3d0a07'-'#0a0807' \) -geometry -160-276 -compose lighten -composite \
    \( -size 3492x1450 radial-gradient:white-'#1a1a1a' \) -compose multiply -composite \
    "$OUT/emblem.png" -geometry +370+254 -compose over -composite \
    -depth 8 -strip "$ETC/home-wallpaper.png"
echo "wrote $ETC/home-wallpaper.png ($(wc -c <"$ETC/home-wallpaper.png" | tr -d ' ') bytes)"
