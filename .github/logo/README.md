# the logo

The wordmark as a strip. Each letter of "emira" sits in its own window, and the loop plays emira's
vocabulary on them: focus walks right, `m` grows and shrinks, `i` moves past `r` and back, `r` stacks
under `i` and leaves again, and the word rests whole. The `e` never moves. It anchors the strip, and
`scene.ts` throws if a step would move it or put another letter before it.

```sh
bun install
bun index.html            # live preview on a light page and a dark one; edits reload
bun render.ts             # out/logo.webp, plus out/logo.png and out/logo.svg at rest
bun render.ts --sheet     # out/sheet.png: each step as it settles, light and dark
bun render.ts --sheet 4.6,6.5   # …or the instants you name
bun run ship              # logo.webp for the README, and the app's golden (below)
```

Needs `brew install webp` for `img2webp`.

## Where things are

| File | What |
| --- | --- |
| `scene.ts` | everything that decides the picture: glyphs, sizes, colours, spring, and `SCRIPT`, the loop |
| `render.ts` | rasterizes with resvg, merges identical frames into one longer frame, encodes lossless |
| `preview.ts` | drives `index.html`: scrub, step through frames, jump to a step |
| `golden.ts` | writes `Tests/EmiraShellTests/WordmarkGolden.swift`: what the app's port is held to |

`frame(t)` is pure and returns an SVG string, so the preview and the renderer draw the same picture.
Motion uses emira's spring, critically damped, in closed form. A step that begins before the
previous one has settled carries its velocity over instead of jumping. `render.ts` refuses a loop
whose last frame doesn't land on its first.

## Two players

The canvas is 472×136 points.

`logo.webp` is the README's copy: 944×272, twice the 472-wide slot it's shown in, at 60 fps. Browsers
turn any frame delay of 10 ms or less into 100 ms, so a 120 fps file would play at about 10 fps. 17 ms
is the shortest that plays on time.

The onboarding window has no copy. It draws the loop itself, every display refresh, from
`Sources/EmiraShell/Onboarding/WordmarkScene.swift`, a port of `scene.ts`. `bun run ship` writes
every window as `windows(t)` places it at two instants of each step into `WordmarkGolden.swift`, and
`WordmarkSceneTests` fails until the port places them the same. A change here is a change there:
edit both, ship, and `make test`.

## Measured

The current loop is 9 s. At 944×272, 60 fps is 1631 KB and 120 fps is 3118 KB.

On the first cut of the loop, which was 8.7 s at 30 fps with 204 distinct frames of 261. The
encodes compare the same way as the loop changes, but rerun them if you need the exact sizes:

| | size |
| --- | --- |
| **lossless** | **858 KB** ← what `render.ts` writes |
| lossless, no drop shadow | 605 KB |
| lossy q90 | 1279 KB, so flat fills don't suit lossy |
| lossless `-m 6` | 860 KB, no gain (and lossy at `-m 6` took minutes rather than ~20 s) |
