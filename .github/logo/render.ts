#!/usr/bin/env bun
//
// `scene.ts`'s loop into an animated webp, plus a still of the word at rest.
//
//   bun render.ts                     out/logo.webp, out/logo.png, out/logo.svg
//   bun render.ts --out <path>        the webp there instead
//   bun run ship                      both shipped copies: the app's, and the README's
//
// The two copies differ because their players do. The app draws at 295×85 points and plays every frame,
// so its copy is 2× that at 120 fps. Browsers clamp any frame of 10 ms or less to 100 ms, so the
// README's is 60 fps — 17 ms frames are the shortest that play on time — at 2× its 472-wide slot.
//   bun render.ts --scale 1           at 1× rather than 2×
//   bun render.ts --fps 60            at that rate rather than scene.ts's
//   bun render.ts --sheet             out/sheet.png: every step as it settles, on light and dark
//   bun render.ts --sheet 6.1,6.2     …or the instants named, in seconds
//
// resvg rasterizes each frame and `img2webp` from libwebp does the animation encode. A run of
// identical frames — the rest, the holds — is written once with the run's duration, so stillness
// costs nothing and the delays carry the timing.
//
// Lossless, because flat fills and hard edges are what it's for: lossy at q90 came out half again
// the size. `-m 6` bought nothing, and made a lossy encode take minutes instead of seconds.

import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Resvg } from "@resvg/resvg-js";
import { DURATION, FPS as SCENE_FPS, HEIGHT, SCRIPT, WIDTH, frame, seam, stepAt } from "./scene.ts";

const args = process.argv.slice(2);
const option = (name: string): string | undefined => {
    const i = args.indexOf(name);
    return i < 0 ? undefined : args[i + 1];
};
const scale = Number(option("--scale") ?? 2);
const FPS = Number(option("--fps") ?? SCENE_FPS);
// Scratch — the stills, the sheet — always lands here; `--out` moves only the webp, so shipping it
// into the app's resources leaves nothing else beside it.
const scratch = join(import.meta.dir, "out");
const out = option("--out") ?? join(scratch, "logo.webp");

const rasterize = (svg: string, zoom = scale) => new Resvg(svg, { fitTo: { mode: "zoom", value: zoom } }).render();

mkdirSync(scratch, { recursive: true });

// --- Sheet ---------------------------------------------------------------------------------------
// For looking at, not shipping: a column of instants, each on a light page and a dark one, since the
// asset is transparent and has to hold up on both.

if (args.includes("--sheet")) {
    const named = option("--sheet");
    const times = named && !named.startsWith("--")
        ? named.split(",").map(Number)
        : SCRIPT.map((_, i) => SCRIPT.slice(0, i + 1).reduce((t, s) => t + s.hold, 0) - 0.001);
    const pages = ["#ffffff", "#0d1117"];
    const cells = times.flatMap((t, row) => pages.map((page, col) => {
        const x = col * WIDTH;
        const y = row * HEIGHT;
        const label = `${t.toFixed(2)}s · ${stepAt(t).step.label}`;
        const ink = col === 0 ? "#57606a" : "#8b949e";
        return `<rect x="${x}" y="${y}" width="${WIDTH}" height="${HEIGHT}" fill="${page}"/>` +
            frame(t).replace("<svg ", `<svg x="${x}" y="${y}" `) +
            `<text x="${x + 8}" y="${y + 16}" font-family="Menlo, monospace" font-size="10" fill="${ink}">${label}</text>`;
    }));
    const sheet = `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH * 2}" height="${HEIGHT * times.length}">${cells.join("")}</svg>`;
    const file = join(scratch, "sheet.png");
    await Bun.write(file, rasterize(sheet, 1).asPng());
    console.log(`logo: wrote ${file} — ${times.length} instants`);
    process.exit(0);
}

// --- Preflight -----------------------------------------------------------------------------------

if (!Bun.which("img2webp")) {
    console.error("logo: img2webp not found — brew install webp");
    process.exit(1);
}

// A loop that doesn't end where it began jumps once a cycle; this catches it before anyone watches.
const gap = seam();
if (gap > 0.05) {
    console.error(`logo: the loop doesn't close — its last frame is ${gap.toFixed(2)}pt from its first.`);
    console.error("      Return the strip to rest in the last step, and hold it long enough to land.");
    process.exit(1);
}

// --- Frames --------------------------------------------------------------------------------------

const work = mkdtempSync(join(tmpdir(), "emira-logo-"));
process.on("exit", () => rmSync(work, { recursive: true, force: true }));

const count = Math.round(DURATION * FPS);
// Each frame's span in whole milliseconds, off a running clock so the delays sum to the loop exactly
// rather than drifting a rounding per frame.
const at = (i: number) => Math.round((i * 1000) / FPS);

const runs: { file: string; ms: number }[] = [];
let last = "";
for (let i = 0; i < count; i++) {
    const image = rasterize(frame(i / FPS));
    const hash = new Bun.CryptoHasher("sha1").update(image.pixels).digest("hex");
    const ms = at(i + 1) - at(i);
    if (hash === last) {
        runs.at(-1)!.ms += ms;
        continue;
    }
    const file = join(work, `f-${String(runs.length).padStart(4, "0")}.png`);
    await Bun.write(file, image.asPng());
    runs.push({ file, ms });
    last = hash;
}

// --- Encode --------------------------------------------------------------------------------------

const encode = Bun.spawnSync([
    "img2webp", "-loop", "0", "-lossless",
    ...runs.flatMap(({ file, ms }) => ["-d", String(ms), file]),
    "-o", out,
]);
if (!encode.success) {
    console.error(`logo: img2webp failed\n${encode.stderr.toString()}`);
    process.exit(1);
}

// The word at rest, for anywhere that can't or shouldn't animate.
const still = frame(0);
await Bun.write(join(scratch, "logo.svg"), still);
await Bun.write(join(scratch, "logo.png"), rasterize(still).asPng());

const kb = (Bun.file(out).size / 1024).toFixed(0);
console.log(`logo: wrote ${out} — ${kb} KB, ${runs.length} distinct of ${count} frames, ` +
    `${DURATION.toFixed(2)}s at ${FPS}fps, ${WIDTH * scale}×${HEIGHT * scale}`);
