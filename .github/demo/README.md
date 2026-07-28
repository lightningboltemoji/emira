# the demo

`demo.sh` is the film in the README, written down. It choreographs one pass over the vocabulary —
open some windows, walk the strip, resize a column, stack and unstack it, cross to another workspace
and back — captions each step in an overlay in the bottom-right corner, and records the lot with
`screencapture`. Run twice, same film.

```sh
.github/demo/demo.sh                # records .github/demo/out/emira-demo.mov
.github/demo/demo.sh --no-record    # rehearse the choreography, record nothing
.github/demo/demo.sh --force        # run with the demo apps already open (see below)
```

## Before you run it

- **The daemon is running** and has Accessibility. `demo.sh` checks by asking it for `debug`.
- **The terminal you run this from has Screen Recording.** `screencapture -v` is what needs it, and
  it inherits the grant from whatever launched it — so the terminal appears in
  System Settings → Privacy & Security → Screen & System Audio Recording, not emira.
- **Workspace 1 is focused and empty, and so is workspace 2.** The script switches to 1 before
  recording, but it can't empty a strip for you.
- **Safari is quit.** Its existing windows would be in the film, and the fullscreen step assumes the
  one window the script opens. `--force` skips the check.
- **Minimize the terminal during the preroll.** Ghostty is necessarily running — you're typing this
  into one of its windows — so instead of refusing, the script prints a line and waits `PREROLL`
  seconds (5) before the camera rolls. Minimize that window in the gap: a minimized window leaves the
  strip like a close, so the four the script then asks for are the only four in the film. This is the
  one precondition nothing checks.

## Knobs

Everything is an environment variable, so a slower or faster cut needs no edit:

| Variable | Default | What it paces |
| --- | --- | --- |
| `LEAD` | `1.1` | a caption on screen before the action it announces |
| `SETTLE` | `1.0` | after an `emira` command |
| `REPEAT_GAP` | `0.45` | between repeats of one command (the four `grow`s) |
| `LAUNCH` | `2.6` | after launching an app |
| `NEW_WINDOW` | `0.9` | after asking a running app for another window |
| `PREROLL` | `5` | your gap to minimize the terminal, before recording starts |
| `CAPTION_SCALE` | `3` | the whole overlay, multiplied — fonts, padding, corner, inset |
| `TERMINAL_APP` | `Ghostty` | the app that fills the strip |
| `BROWSER_APP` | `Safari` | the app on workspace 2 |
| `OUT` | `out/emira-demo.mov` | where the film lands |
| `DISPLAY_INDEX` | `1` | which display to record (1 is main) |
| `EMIRA` | — | the CLI to drive; otherwise the first of `/Applications/emira.app`, `dist/`, `.build/release`, `$PATH` |

## The overlay

`caption.swift` is an ~150-line AppKit panel, compiled on demand into `.build/caption` and driven
over a fifo — one caption per line, `mono|description`, blank to hide, EOF to quit.

Every dimension in it is a base point size times `CAPTION_SCALE`, which defaults to **3**: the film
is downscaled to a small webp, and the caption is the one thing on screen that has to survive that
shrink — the desktop behind it is allowed to get small, the text isn't.

It sits at
`.screenSaver` level deliberately: emira's own cover is `.floating`, and a caption drawn under it
would be baked into the captured base and freeze for the length of every transition, including the
caption change announcing the next step.

It is borderless and reports no subrole, so emira's taxonomy floats it rather than tiling it, and
it is a non-activating panel, so it never takes the focus the choreography's commands act on.

## Turning it into a webp

```sh
.github/demo/webp.sh          # out/emira-demo.mov -> out/emira-demo.webp
.github/demo/webp.sh --fit    # …and walk quality down until it's under TARGET_MB
```

Needs `brew install ffmpeg webp`. Two tools because neither does the job alone: Homebrew's ffmpeg
carries the webp *muxer* but not the libwebp *encoder*, so it decodes, resamples and scales, and
`img2webp` does the animation encode — which is the half worth controlling anyway, since it exposes
per-frame quality and compression method.

| Variable | Default | Notes |
| --- | --- | --- |
| `SCALE` | `1/3` | linear, and **a ceiling** — all the resolution the clip needs, not a compromise. `screencapture` records *pixels*, so on Retina a third is still two-thirds of logical size |
| `QUALITY` | `90` | with the resolution capped, this is where the budget goes. `--fit` walks it down (85 → 75 → 65 → 55) |
| `FPS` | `24` | the last knob to cut: at 15 a 300 ms transition is four frames and emira looks like the thing it was built not to be |
| `METHOD` | `4` | `6` bought 4% at ~10× the encode time; `-min_size` bought nothing |
| `TARGET_MB` | `5` | what `--fit` aims under, and what a plain run warns about |

Measured on a 38 s take at a third (1200×778, 928 frames), so you can pick without guessing:

| quality | size |
| --- | --- |
| 75 | 1.64 MB |
| 85 | 2.72 MB |
| **90** | **3.26 MB** ← default |
| 95 | 5.93 MB — over |

A whole run is ~17 s. Re-encodes reuse the extracted frames, so `--fit`'s extra attempts cost
seconds each — the slow half is decoding, and it happens once.

**Why not seek with AVFoundation.** `screencapture` writes variable-rate HEVC, and random access into
it is unreliable: `AVAssetImageGenerator` answers `Cannot Decode` for over half of evenly-spaced
requests on a file whose frames all decode fine in sequence. ffmpeg's `fps=` filter reads
sequentially and resamples to a constant rate, which is both correct and what `img2webp`'s uniform
`-d` assumes.
