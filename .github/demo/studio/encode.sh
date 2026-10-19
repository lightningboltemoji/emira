#!/usr/bin/env bash
# Encodes a render as an animated WebP, which GitHub plays inline, looped, where a video waits for a
# click: WIDTH wide at FPS, lossless, since lossy leaves blocks wherever something fades. Fails if
# it's over `limit` bytes (an image upload's 10 MB).
# Usage: encode.sh render.mp4 out.webp [limit]
set -euo pipefail
in="$1"
out="$2"
limit="${3:-10000000}"
WIDTH="${WIDTH:-800}"
FPS="${FPS:-60}"

for tool in ffmpeg img2webp; do
  command -v $tool >/dev/null || { echo "error: needs $tool (brew install ffmpeg webp)" >&2; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ffmpeg -v error -i "$in" -vf "fps=$FPS,scale=$WIDTH:-2:flags=lanczos" "$tmp/%05d.png"

# Each frame lasts until the next one's time, rounded to the millisecond, so 60 fps plays as 17, 17
# and 16 ms rather than drifting at 16.
frames=("$tmp"/*.png)
{
  echo "-loop 0 -lossless"
  for i in "${!frames[@]}"; do
    echo "-d $(( ((i + 1) * 1000 + FPS / 2) / FPS - (i * 1000 + FPS / 2) / FPS )) ${frames[i]}"
  done
  echo "-o $out"
} > "$tmp/args"
img2webp "$tmp/args" >/dev/null 2>&1

size=$(stat -f %z "$out")
echo "$out: ${#frames[@]} frames at $WIDTH wide, $size bytes"
if ((size > limit)); then
  echo "error: over $limit bytes; a smaller WIDTH or FPS will fit" >&2
  exit 1
fi
