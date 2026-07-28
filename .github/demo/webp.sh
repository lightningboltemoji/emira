#!/usr/bin/env bash
#
# `demo.sh`'s .mov into an animated webp small enough to live in the README.
#
#   ./webp.sh                       out/emira-demo.mov -> out/emira-demo.webp
#   ./webp.sh --fit                 …and walk the quality down until it fits TARGET_MB
#   ./webp.sh some.mov -o some.webp
#
# Two tools, because neither does the job alone: ffmpeg decodes, resamples and scales (Homebrew's
# ffmpeg carries the webp *muxer* but not the libwebp *encoder*, so it cannot write webp itself), and
# `img2webp` from libwebp does the animation encode — which is the half worth having control over
# anyway, since it exposes per-frame quality and compression method.
#
# `screencapture` records variable-rate HEVC, and seeking into it is unreliable: AVFoundation's frame
# generator answers "Cannot Decode" for over half of evenly-spaced requests on a file whose frames all
# decode fine in sequence. ffmpeg's `fps` filter reads sequentially and resamples to a constant rate,
# which is both correct and what `img2webp`'s uniform `-d` assumes.

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Knobs ---------------------------------------------------------------------------------------

# The linear scale factor, and **a third is the ceiling** — it is all the resolution the clip needs,
# not a budget compromise. `screencapture` records *pixels*, so a Retina display records at 2× its
# point size and a third of that is still two-thirds of logical size. Written as a fraction because
# it goes straight into the ffmpeg expression below, where it stays exact.
SCALE="${SCALE:-1/3}"
# The demo's subject is smooth motion, so this is the knob to cut last: at 15 a 300 ms transition is
# four frames and emira looks like the thing it was built not to be. Static stretches cost almost
# nothing per frame, so raising it is cheaper than it looks.
FPS="${FPS:-24}"
# With the resolution capped, quality is where the remaining budget goes. Measured on a 38 s take at
# a third: q75 1.6 MB, q85 2.7, q90 3.2, q95 5.9 — so 90 is the last rung with real headroom under
# the 5 MB target, and 95 nearly doubles it for very little.
QUALITY="${QUALITY:-95}"
# img2webp's own default. `-m 6` bought 4% at ~10× the encode time, and `-min_size` bought nothing.
METHOD="${METHOD:-4}"
TARGET_MB="${TARGET_MB:-7}"

INPUT="${INPUT:-$DEMO_DIR/out/emira-demo.mov}"
OUTPUT=""
FIT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fit)     FIT=1; shift ;;
        -o)        OUTPUT="$2"; shift 2 ;;
        -h|--help) awk '/^#!/{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*)        echo "webp: unknown option '$1'" >&2; exit 2 ;;
        *)         INPUT="$1"; shift ;;
    esac
done
[[ -n "$OUTPUT" ]] || OUTPUT="${INPUT%.*}.webp"

# --- Preflight -----------------------------------------------------------------------------------

[[ -f "$INPUT" ]] || { echo "webp: no such file '$INPUT' — run demo.sh first" >&2; exit 1; }
command -v ffmpeg   >/dev/null || { echo "webp: ffmpeg not found — brew install ffmpeg" >&2; exit 1; }
command -v img2webp >/dev/null || { echo "webp: img2webp not found — brew install webp" >&2; exit 1; }

source_size="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
                       -of csv=p=0:s=x "$INPUT")"
seconds="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT")"
printf 'webp: source %s — %s, %.1fs\n' "$INPUT" "$source_size" "$seconds"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/emira-webp.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

# --- Decode --------------------------------------------------------------------------------------
# Dimensions forced even: lossy webp is YUV420, and an odd axis costs a row of chroma artefacts.

echo "webp: extracting frames at ${FPS}fps, scale ${SCALE}…"
ffmpeg -v error -i "$INPUT" \
    -vf "fps=${FPS},scale=w=trunc(iw*${SCALE}/2)*2:h=trunc(ih*${SCALE}/2)*2:flags=lanczos" \
    -f image2 "$WORK/f-%05d.png"

frames=$(find "$WORK" -name 'f-*.png' | wc -l | tr -d ' ')
[[ "$frames" -gt 0 ]] || { echo "webp: ffmpeg produced no frames" >&2; exit 1; }
size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$WORK/f-00001.png")
echo "webp: $frames frames at $size"

# --- Encode --------------------------------------------------------------------------------------

DELAY=$(( 1000 / FPS ))          # per-frame duration in ms; uniform, because `fps=` made it constant

encode() {
    img2webp -loop 0 -lossy -q "$1" -m "$METHOD" -d "$DELAY" "$WORK"/f-*.png -o "$OUTPUT" >/dev/null 2>&1
    stat -f%z "$OUTPUT"
}

megabytes() { awk -v bytes="$1" 'BEGIN { printf "%.2f", bytes / 1048576 }'; }

bytes=$(encode "$QUALITY")
echo "webp: q=$QUALITY → $(megabytes "$bytes") MB"

# Quality first, because it is the only knob that costs nothing structural — fps is the subject and
# scale is already at the resolution the clip wants. Re-encodes reuse the extracted frames, so each
# attempt is seconds.
limit=$(( TARGET_MB * 1048576 ))
if [[ $FIT -eq 1 ]]; then
    for quality in 85 75 65 55; do
        [[ $bytes -le $limit ]] && break
        bytes=$(encode "$quality")
        echo "webp: q=$quality → $(megabytes "$bytes") MB"
        QUALITY=$quality
    done
fi

echo "webp: wrote $OUTPUT — $(megabytes "$bytes") MB at q=$QUALITY, ${FPS}fps, $size"

if [[ $bytes -gt $limit ]]; then
    echo "webp: over the ${TARGET_MB} MB target. Turn a knob:" >&2
    echo "      --fit          walk quality down automatically — start here" >&2
    echo "      SCALE=1/4      smaller image; a third is the most this clip needs, never more" >&2
    echo "      FPS=15         choppier, but the last thing you want to cut here" >&2
    exit 1
fi
