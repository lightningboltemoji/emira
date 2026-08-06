#!/usr/bin/env bash
#
# The emira demo: one choreographed sequence of shell + `emira` calls, captioned by an overlay in the
# bottom-right corner and recorded with `screencapture`. Running it twice gives the same film, which
# is the whole point — the README's clip should be reproducible from a checkout rather than from a
# lucky take.
#
#   ./demo.sh                 record out/emira-demo.mov
#   ./demo.sh --no-record     rehearse the choreography without recording
#   ./demo.sh --force         run even though a guest app is already open
#
# Three apps, because a tiler shown one app at a time looks like a feature of that app: a terminal and
# a browser share workspace 1, a calendar has workspace 2 to itself. Nothing in the choreography knows
# which apps they are — `TERMINAL_APP`, `BROWSER_APP` and `CALENDAR_APP` are just names to launch.
#
# Preconditions. Checked: the daemon is running, and the guest apps are quit. Not checked, and yours
# to arrange: the terminal you run this from has Screen Recording (`screencapture -v` needs it),
# workspaces 1 and 2 are both empty, and the guest apps were last used on *this* Space — macOS reopens
# an app where it last was, and emira does not manage the Spaces it isn't on, so an app that opens over
# there never reaches the strip. The wait says so when it happens.
#
# The terminal is one of the apps in the film, which means the window you launch this from is one of
# its windows. So there is a preroll (`PREROLL`, 5 s) before the camera rolls: minimize this window
# during it. A minimized window leaves the strip like a close, so the windows the script then asks for
# are the only ones in the film.
#
# Every pause is a variable at the top. `screencapture` is stopped with SIGINT rather than given a
# `-V` duration, so the film is exactly as long as the choreography and nobody has to keep a total in
# sync with the steps.

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DEMO_DIR/../.." && pwd)"

# --- Knobs ---------------------------------------------------------------------------------------

TERMINAL_APP="${TERMINAL_APP:-Ghostty}"
BROWSER_APP="${BROWSER_APP:-Google Chrome}"
CALENDAR_APP="${CALENDAR_APP:-Calendar}"
OUT="${OUT:-$DEMO_DIR/out/emira-demo.mov}"
DISPLAY_INDEX="${DISPLAY_INDEX:-1}"

# How long a caption sits on screen before the action it announces. Long enough to read a short line,
# and no longer: the film is a sequence of 300 ms transitions and reads as slow the moment the
# captions outstay them.
LEAD="${LEAD:-0.65}"
# After an `emira` command: the transition is ~0.3 s, the rest is so the eye can land on the result.
SETTLE="${SETTLE:-0.9}"
# Between the repeats of a repeated command — deliberately tight, so three `grow`s read as one gesture.
REPEAT_GAP="${REPEAT_GAP:-0.6}"
# After a window arrives, which is the same beat as SETTLE — a window landing is a transition like any
# other. Named separately because it is the one that also absorbs the app drawing its first frame.
ARRIVE="${ARRIVE:-0.7}"
# A ceiling, not a pace: how long a launch may take before the demo gives up on it and says so.
LAUNCH_TIMEOUT="${LAUNCH_TIMEOUT:-15}"
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

command -v swiftc  >/dev/null || { echo "demo: swiftc not found (install Command Line Tools)" >&2; exit 1; }
command -v python3 >/dev/null || { echo "demo: python3 not found (install Command Line Tools)" >&2; exit 1; }

# The bundle id is how the choreography waits for a window, and asking Launch Services for it also
# answers whether the app is there at all — worth knowing before the camera rolls rather than eight
# seconds into a take.
bundle_id() {
    local id
    id="$(osascript -e "id of app \"$1\"" 2>/dev/null || true)"
    [[ -n "$id" ]] || { echo "demo: no app named '$1' — set TERMINAL_APP/BROWSER_APP/CALENDAR_APP" >&2; exit 1; }
    echo "$id"
}

TERMINAL_ID="$(bundle_id "$TERMINAL_APP")"
BROWSER_ID="$(bundle_id "$BROWSER_APP")"
CALENDAR_ID="$(bundle_id "$CALENDAR_APP")"

is_running() {
    [[ "$(osascript -e "application \"$1\" is running" 2>/dev/null)" == "true" ]]
}

# Only the guests: the terminal is necessarily running, because this script is being typed into one of
# its windows. That window is handled by the preroll instead (minimize it), which is a thing the
# script can ask for but cannot check.
if [[ $FORCE -eq 0 ]]; then
    for guest in "$BROWSER_APP" "$CALENDAR_APP"; do
        if is_running "$guest"; then
            echo "demo: $guest is already running — its existing windows would be in the film, and" >&2
            echo "      the fullscreen step assumes the one window this script opens." >&2
            echo "      Quit it, or pass --force." >&2
            exit 1
        fi
    done
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

# How many windows the daemon currently has for a bundle id. `world.windows` is the flat
# [id, record, id, record…] array Swift encodes an integer-keyed dictionary as, so the records are
# every second element.
tracked_windows() {
    "$EMIRA" debug | python3 -c '
import json, sys
flat = json.load(sys.stdin)["world"]["windows"]
print(sum(1 for record in flat[1::2] if record.get("bundleId") == sys.argv[1]))
' "$1"
}

# Wait until the strip has one more window of $1 than it had at $2, then let the arrival land.
#
# The thing being waited on is emira placing the window, not the app calling itself launched — that is
# what the next frame depends on, and it is the only version of "ready" the film can see. A fixed
# sleep would have to cover a cold Chrome and would then pay that on every take, including the ones
# where the app was already warm.
#
# The timeout is nearly always the Space: macOS reopens an app on the Space it was last used on, and a
# window over there is off screen, so emira leaves it alone and the strip never gains it.
await_window() {
    local bundle="$1" was="$2" deadline=$((SECONDS + LAUNCH_TIMEOUT))
    while [[ "$(tracked_windows "$bundle")" -le "$was" ]]; do
        if (( SECONDS >= deadline )); then
            echo "demo: no window from $bundle within ${LAUNCH_TIMEOUT}s — the film will be a window short." >&2
            echo "      It most likely opened on another Space; drag it back to this one and rerun." >&2
            return
        fi
        sleep 0.1
    done
    sleep "$ARRIVE"
}

# Launch an app that isn't running.
open_app() {
    local was; was="$(tracked_windows "$2")"
    open -a "$1"
    await_window "$2" "$was"
}

# Another window from an app that is already running.
#
# `new window`, and deliberately **not** the standard suite's `make new window` with this as a
# fallback: under Ghostty that spelling *opens the window* and then fails returning a reference to it
# (`Can't make class window id tab-group-…`, -2710), so a fallback chained behind it opens a second
# one every time. A command whose failure still has an effect can't carry a fallback.
#
# A refusal is reported rather than swallowed: a missing window doesn't fail anything, it just quietly
# makes the film wrong.
new_window() {
    local was; was="$(tracked_windows "$2")"
    osascript -e "tell application \"$1\" to new window" >/dev/null 2>&1 \
        || echo "demo: $1 refused 'new window' over AppleScript — the film will be a window short" >&2
    await_window "$2" "$was"
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

caption "new window" "a terminal arrives on the strip"
new_window "$TERMINAL_APP" "$TERMINAL_ID"

caption "emira grow 10%" "widen its column"
emira_repeat 3 grow 10%

caption "open -a $BROWSER_APP" "a second app opens its own column"
open_app "$BROWSER_APP" "$BROWSER_ID"

caption "emira cycle-width" "rotate through width presets — a third, a half, two thirds"
emira_repeat 2 cycle-width

caption "emira focus left / right" "the strip scrolls to the focused window"
"$EMIRA" focus left;  sleep "$REPEAT_GAP"
"$EMIRA" focus right; sleep "$REPEAT_GAP"
"$EMIRA" focus left;  sleep "$SETTLE"

caption "emira move-window right" "swap the two columns"
emira_do move-window right

caption "emira focus-workspace 2" "switch to another workspace"
emira_do focus-workspace 2

caption "open -a $CALENDAR_APP" "calendar arrives on the the strip"
open_app "$CALENDAR_APP" "$CALENDAR_ID"

caption "emira fullscreen" "stretch to fill the viewport"
emira_do fullscreen

caption "emira focus-workspace 1" "pick up where we left off on the other workspace"
emira_do focus-workspace 1
sleep 0.8

caption "" ""
sleep 0.6

# --- Done ------------------------------------------------------------------------------------------

cleanup
trap - EXIT INT TERM

if [[ $RECORD -eq 1 ]]; then
    echo "demo: wrote $OUT"
else
    echo "demo: rehearsal finished (nothing recorded)"
fi
