#!/usr/bin/env bash
#
# The emira demo: one choreographed sequence of shell + `emira` calls, captioned by an overlay in the
# bottom-right corner and recorded with `screencapture`. Running it twice gives the same film, which
# is the whole point — the README's clip should be reproducible from a checkout rather than from a
# lucky take.
#
#   ./demo.sh                 record out/emira-demo.mov
#   ./demo.sh --no-record     rehearse the choreography without recording
#   ./demo.sh --force         run even though the browser is already open
#
# Preconditions. Checked: the daemon is running, and the browser is quit. Not checked, and yours to
# arrange: the terminal you run this from has Screen Recording (`screencapture -v` needs it), and
# workspaces 1 and 2 are both empty.
#
# The terminal is the app the demo fills the strip with, which means the window you launch this from
# is one of its windows. So there is a preroll (`PREROLL`, 5 s) before the camera rolls: minimize
# this window during it. A minimized window leaves the strip like a close, so the four the script
# then asks for are the only four in the film.
#
# Every pause is a variable at the top. `screencapture` is stopped with SIGINT rather than given a
# `-V` duration, so the film is exactly as long as the choreography and nobody has to keep a total in
# sync with the steps.

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DEMO_DIR/../.." && pwd)"

# --- Knobs ---------------------------------------------------------------------------------------

TERMINAL_APP="${TERMINAL_APP:-Ghostty}"
BROWSER_APP="${BROWSER_APP:-Safari}"
OUT="${OUT:-$DEMO_DIR/out/emira-demo.mov}"
DISPLAY_INDEX="${DISPLAY_INDEX:-1}"

# How long a caption sits on screen before the action it announces. Long enough to read a short line.
LEAD="${LEAD:-1.1}"
# After an `emira` command: the transition is ~0.3 s, the rest is so the eye can land on the result.
SETTLE="${SETTLE:-1.0}"
# Between the repeats of a repeated command — deliberately tight, so four `grow`s read as one gesture.
REPEAT_GAP="${REPEAT_GAP:-0.45}"
# After launching an app, which is the one thing here that waits on somebody else's cold start.
LAUNCH="${LAUNCH:-2.6}"
# After asking a running app for another window.
NEW_WINDOW="${NEW_WINDOW:-0.7}"
# Your window on the clock: minimize the terminal you launched this from before the camera rolls.
PREROLL="${PREROLL:-5}"

RECORD=1
FORCE=0
for argument in "$@"; do
    case "$argument" in
        --no-record) RECORD=0 ;;
        --force)     FORCE=1 ;;
        # The header comment *is* the help text — stop at the first line that isn't one.
        -h|--help)   awk '/^#!/{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"
                     exit 0 ;;
        *)           echo "demo: unknown option '$argument'" >&2; exit 2 ;;
    esac
done

# --- Locating the CLI ----------------------------------------------------------------------------
# The bundled copy first: `make app` puts the CLI inside emira.app next to the daemon it must agree
# with on the wire protocol. `.build/release` is the working-tree equivalent.

find_cli() {
    if [[ -n "${EMIRA:-}" ]]; then echo "$EMIRA"; return; fi
    for candidate in \
        "/Applications/emira.app/Contents/MacOS/emira" \
        "$REPO_ROOT/dist/emira.app/Contents/MacOS/emira" \
        "$REPO_ROOT/.build/release/emira" \
        "$REPO_ROOT/.build/debug/emira"
    do
        [[ -x "$candidate" ]] && { echo "$candidate"; return; }
    done
    command -v emira || true
}

EMIRA="$(find_cli)"
[[ -x "$EMIRA" ]] || {
    echo "demo: no emira CLI found — run 'make app', or set EMIRA=/path/to/emira" >&2
    exit 1
}

# --- Preflight -----------------------------------------------------------------------------------

# `debug` is a read: it proves the daemon is up without touching the desktop. Exit 69 is its own
# answer (EX_UNAVAILABLE, the CLI's code for an unreachable daemon).
if ! "$EMIRA" debug >/dev/null 2>&1; then
    echo "demo: the emira daemon isn't answering — launch emira.app first" >&2
    exit 1
fi

command -v swiftc >/dev/null || { echo "demo: swiftc not found (install Command Line Tools)" >&2; exit 1; }

is_running() {
    [[ "$(osascript -e "application \"$1\" is running" 2>/dev/null)" == "true" ]]
}

# Only the browser: the terminal is necessarily running, because this script is being typed into one
# of its windows. That window is handled by the preroll instead (minimize it), which is a thing the
# script can ask for but cannot check.
if [[ $FORCE -eq 0 ]] && is_running "$BROWSER_APP"; then
    echo "demo: $BROWSER_APP is already running — its existing windows would be in the film, and" >&2
    echo "      the fullscreen step assumes the one window this script opens." >&2
    echo "      Quit it, or pass --force." >&2
    exit 1
fi

# --- The caption overlay -------------------------------------------------------------------------
# Compiled on demand into .build/ (gitignored) and reused until the source is newer. Pinned to Swift 5
# because this is a standalone file with top-level code, not a package target.

CAPTION_SRC="$DEMO_DIR/caption.swift"
CAPTION_BIN="$DEMO_DIR/.build/caption"

if [[ ! -x "$CAPTION_BIN" || "$CAPTION_SRC" -nt "$CAPTION_BIN" ]]; then
    mkdir -p "$(dirname "$CAPTION_BIN")"
    echo "demo: building the caption overlay…"
    swiftc -O -swift-version 5 -o "$CAPTION_BIN" "$CAPTION_SRC"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/emira-demo.XXXXXX")"
FIFO="$WORK/captions"
mkfifo "$FIFO"

CAPTION_PID=""
RECORDER_PID=""

cleanup() {
    # Order matters: stop the recorder first so the film doesn't end on the caption vanishing.
    if [[ -n "$RECORDER_PID" ]]; then
        kill -INT "$RECORDER_PID" 2>/dev/null || true
        wait "$RECORDER_PID" 2>/dev/null || true
        RECORDER_PID=""
    fi
    exec 3>&- 2>/dev/null || true      # EOF on the fifo is how the overlay is asked to quit
    if [[ -n "$CAPTION_PID" ]]; then
        wait "$CAPTION_PID" 2>/dev/null || true
        CAPTION_PID=""
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

"$CAPTION_BIN" < "$FIFO" &
CAPTION_PID=$!
exec 3> "$FIFO"                        # held open, so the overlay never sees EOF mid-demo

# --- The verbs the choreography is written in ----------------------------------------------------

# Put a caption up and let it be read. First half is set in mono (the command actually being run),
# second half is the plain-English gloss.
caption() {
    printf '%s|%s\n' "${1:-}" "${2:-}" >&3
    sleep "$LEAD"
}

# Run one `emira` command and let the strip settle. `$1…` are the CLI's own words.
emira_do() {
    "$EMIRA" "$@"
    sleep "$SETTLE"
}

# The same command N times, tight enough to read as one continuous gesture.
emira_repeat() {
    local count="$1"; shift
    local index=1
    while [[ $index -le $count ]]; do
        "$EMIRA" "$@"
        if [[ $index -lt $count ]]; then sleep "$REPEAT_GAP"; else sleep "$SETTLE"; fi
        index=$((index + 1))
    done
}

# Another window from an app that is already running.
#
# `new window`, and deliberately **not** the standard suite's `make new window` with this as a
# fallback: under Ghostty that spelling *opens the window* and then fails returning a reference to it
# (`Can't make class window id tab-group-…`, -2710), so a fallback chained behind it opens a second
# one every time. A command whose failure still has an effect can't carry a fallback.
#
# A refusal is reported rather than swallowed: a missing window doesn't fail anything, it just
# quietly makes the film wrong (the focus walk counts on four).
new_window() {
    osascript -e "tell application \"$1\" to new window" >/dev/null 2>&1 \
        || echo "demo: $1 refused 'new window' over AppleScript — the film will be a window short" >&2
    sleep "$NEW_WINDOW"
}

# --- Setup, before the camera rolls ---------------------------------------------------------------

# The minimize lands *before* the workspace switch on purpose: it is a structural edit like any other
# and opens a transition, and we want that finished rather than half-animated on the first frame.
echo "demo: minimize this window — recording starts in ${PREROLL}s"
sleep "$PREROLL"

"$EMIRA" focus-workspace 1
sleep 0.6

if [[ $RECORD -eq 1 ]]; then
    mkdir -p "$(dirname "$OUT")"
    rm -f "$OUT"
    # -v record, -x no shutter sounds, -D the display. No -C: a keyboard-driven WM demo is quieter
    # without a cursor drifting through it.
    screencapture -v -x -D "$DISPLAY_INDEX" "$OUT" &
    RECORDER_PID=$!
    sleep 1.5                          # the recorder takes a beat to actually start writing frames
fi

# --- The choreography ------------------------------------------------------------------------------

caption "" ""                          # open on a clean desktop

caption "new window" "a window arrives and takes the strip"
new_window "$TERMINAL_APP"
sleep "$SETTLE"

caption "new window ×3" "each one opens its own column, right of the focused one"
new_window "$TERMINAL_APP"
new_window "$TERMINAL_APP"
new_window "$TERMINAL_APP"
sleep "$SETTLE"

caption "emira focus left" "walk back down the strip to the first window"
emira_repeat 3 focus left

caption "emira grow 10%" "widen the column — a percentage of the working area, so the steps are even"
emira_repeat 4 grow 10%

caption "emira shrink 10%" "and back one step; grow and shrink are exact inverses"
emira_do shrink 10%

caption "emira consume-or-expel down" "swallow the next column into this one — now it's a stack"
emira_do consume-or-expel down

caption "emira move-window down" "reorder the stack"
emira_do move-window down

caption "emira consume-or-expel up" "expel it back out into a column of its own"
emira_do consume-or-expel up

caption "emira focus-workspace 2" "36 workspaces, each its own infinite strip"
emira_do focus-workspace 2

caption "open -a $BROWSER_APP" "opening onto an empty strip"
open -a "$BROWSER_APP"
sleep "$LAUNCH"

caption "emira fullscreen" "the strip's fullscreen: no Space, the neighbours just park"
emira_do fullscreen

caption "emira focus-workspace 1" "back where we were, scroll offset and focus remembered"
emira_do focus-workspace 1
sleep 1.2

caption "" ""
sleep 0.8

# --- Done ------------------------------------------------------------------------------------------

cleanup
trap - EXIT INT TERM

if [[ $RECORD -eq 1 ]]; then
    echo "demo: wrote $OUT"
else
    echo "demo: rehearsal finished (nothing recorded)"
fi
