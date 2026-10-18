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
bun run ship              # both committed copies (below)
```

Needs `brew install webp` for `img2webp`.

## Where things are

| File | What |
| --- | --- |
| `scene.ts` | everything that decides the picture: glyphs, sizes, colours, spring, and `SCRIPT`, the loop |
| `render.ts` | rasterizes with resvg, merges identical frames into one longer frame, encodes lossless |
| `preview.ts` | drives `index.html`: scrub, step through frames, jump to a step |

`frame(t)` is pure and returns an SVG string, so the preview and the renderer draw the same picture.
Motion uses emira's spring, critically damped, in closed form. A step that begins before the
previous one has settled carries its velocity over instead of jumping. `render.ts` refuses a loop
whose last frame doesn't land on its first.

## Two copies

The canvas is 472×136 points. `bun run ship` writes two copies, because the two players differ:

| Copy | Size | Rate | Why |
| --- | --- | --- | --- |
| `Sources/EmiraShell/Resources/logo.webp` | 590×170 | 120 fps | the onboarding window draws it at 295×85 points, so this is exactly 2×. `Wordmark.swift` reads the unclamped delays and paces frames by the display refresh |
| `.github/logo/logo.webp` | 944×272 | 60 fps | the README shows it 472 wide. Browsers turn any frame delay of 10 ms or less into 100 ms, so a 120 fps file would play at about 10 fps. 17 ms is the shortest that plays on time |

Change the onboarding size and you have to change `Wordmark.size` and the `--scale` in `ship` together.

## Measured

The current loop is 9 s. At 944×272, 60 fps is 1631 KB and 120 fps is 3118 KB. The app's copy is
1922 KB, because it's smaller. ImageIO decodes a frame in about 1 ms at any of these rates.

On the first cut of the loop, which was 8.7 s at 30 fps with 204 distinct frames of 261. The
encodes compare the same way as the loop changes, but rerun them if you need the exact sizes:

| | size |
| --- | --- |
| **lossless** | **858 KB** ← what `render.ts` writes |
| lossless, no drop shadow | 605 KB |
| lossy q90 | 1279 KB, so flat fills don't suit lossy |
| lossless `-m 6` | 860 KB, no gain (and lossy at `-m 6` took minutes rather than ~20 s) |
