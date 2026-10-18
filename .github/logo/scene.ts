// The wordmark as a strip: each letter of "emira" is a window, and the loop is emira's vocabulary
// played on them — focus walks, a column grows and shrinks, a window moves past its neighbour, two
// windows stack into one column and part again — before the word rests whole.
//
// Pure: `frame(t)` is an SVG string and nothing here touches a DOM, so the preview page and the
// renderer draw the same picture from the same code.
//
// **The `e` never moves.** It anchors the strip, so whatever happens to its right, the word still
// starts where it starts — and no step may put another letter first.

// --- Canvas --------------------------------------------------------------------------------------
// In points, exported at 2×. As tall as a window and its shadow need; as wide as the strip plus a grow,
// since the `e` holds still and a grow pushes everything after it right. `Wordmark.swift` and the
// README both draw at this aspect.

export const WIDTH = 472;
export const HEIGHT = 136;

// --- Look ----------------------------------------------------------------------------------------

const X_HEIGHT = 40;          // a letter's x-height at rest, in points
const STROKE = 0.19;          // in x-heights: the pen is monoline, like the wordmark before it
const WINDOW_HEIGHT = 104;
const COLUMN_GAP = 8;
const WINDOW_GAP = 6;         // between windows stacked in one column
const PAD_X = 16;             // either side of a letter, at rest
const PAD_Y = 14;
const RADIUS = 9;
const UNFOCUSED_OPACITY = 0.32;

// The app icon's greens. Windows are a vertical gradient and letters are white, which reads on both a
// light and a dark page — the asset is transparent, so it has to.
const WINDOW_TOP = "#23a862";
const WINDOW_BOTTOM = "#0f8b4d";
const INK = "#ffffff";

// --- Motion --------------------------------------------------------------------------------------
// emira's own spring: critically damped, so nothing overshoots. emira's default stiffness is 800,
// which on a logo nobody has learned to read yet is a touch quick.

const STIFFNESS = 320;
const OMEGA = Math.sqrt(STIFFNESS);
// The app's rate: `Wordmark.swift` reads unclamped delays and paces by the display, so it can play
// every frame on a 120 Hz screen. Browsers can't — see `bun run ship`.
export const FPS = 120;

// A grow or shrink, in points of column width.
const RESIZE_STEP = 40;

// --- The loop ------------------------------------------------------------------------------------
// Each step happens, then `hold` seconds pass before the next. Commands are emira's, acting on the
// focused window the way the daemon would. The last step must leave the strip as the first found
// it, and hold long enough for the spring to land — `render.ts` checks both.

type Letter = "e" | "m" | "i" | "r" | "a";

export interface Step {
    hold: number;
    label: string;
    focus?: Letter | null;
    resize?: number;
    move?: -1 | 1;
    consume?: -1 | 1;
    expel?: -1 | 1;
}

export const SCRIPT: Step[] = [
    { hold: 1.6, label: "rest" },
    { hold: 0.75, label: "focus e", focus: "e" },
    { hold: 0.55, label: "focus right", focus: "m" },
    { hold: 0.75, label: "grow", resize: +RESIZE_STEP },
    { hold: 0.6, label: "shrink", resize: -RESIZE_STEP },
    { hold: 0.55, label: "focus right", focus: "i" },
    { hold: 0.75, label: "move-window right", move: +1 },
    { hold: 0.6, label: "move-window left", move: -1 },
    { hold: 0.55, label: "focus right", focus: "r" },
    { hold: 1.0, label: "consume-or-expel left", consume: -1 },
    { hold: 0.6, label: "consume-or-expel right", expel: +1 },
    { hold: 0.7, label: "unfocus", focus: null },
];

// --- Glyphs --------------------------------------------------------------------------------------
// Drawn on a centreline in x-height units, y up from the baseline, so a stroke of STROKE sits exactly
// on 0 and 1. `width` is the inked width, stroke included. The `i`'s dot is the one thing above the
// x-height, and every letter shares its box so baselines agree.

interface Glyph {
    width: number;
    d: string;
    dot?: [number, number];
}

const S = STROKE;
const R = (1 - S) / 2;                 // a bowl's radius: the e's, the a's
const TOP = 1 - S / 2;                 // the x-height, on the centreline
const BASE = S / 2;
const DOT_Y = 1.32;
const DOT_R = 0.125;
const GLYPH_TOP = DOT_Y + DOT_R;
// The glyph-space height placed at a window's vertical centre — between the x-height's middle and the
// box's, so the dot doesn't drag every letter down.
const ANCHOR = 0.62;

const f = (n: number) => +n.toFixed(4);
const pt = (x: number, y: number) => `${f(x)} ${f(y)}`;
const polar = (cx: number, cy: number, r: number, deg: number): [number, number] =>
    [cx + r * Math.cos((deg * Math.PI) / 180), cy + r * Math.sin((deg * Math.PI) / 180)];

const GLYPHS: Record<Letter, Glyph> = {
    e: (() => {
        const cx = S / 2 + R;
        const [ex, ey] = polar(cx, 0.5, R, 318);
        // The bar, then round from its right end over the top and out at the lower right.
        return { width: 2 * R + S, d: `M${pt(cx - R, 0.5)}L${pt(cx + R, 0.5)}A${f(R)} ${f(R)} 0 1 1 ${pt(ex, ey)}` };
    })(),
    m: (() => {
        const ra = 0.3;
        const x0 = S / 2;
        const cy = TOP - ra;
        const arch = (x: number) => `M${pt(x, cy)}A${ra} ${ra} 0 0 0 ${pt(x + 2 * ra, cy)}L${pt(x + 2 * ra, BASE)}`;
        return { width: 4 * ra + S, d: `M${pt(x0, BASE)}L${pt(x0, TOP)}${arch(x0)}${arch(x0 + 2 * ra)}` };
    })(),
    i: { width: S, d: `M${pt(S / 2, BASE)}L${pt(S / 2, TOP)}`, dot: [S / 2, DOT_Y] },
    r: (() => {
        const rr = 0.38;
        const x0 = S / 2;
        const cy = TOP - rr;
        const [ex, ey] = polar(x0 + rr, cy, rr, 55);
        return { width: ex + S / 2, d: `M${pt(x0, BASE)}L${pt(x0, TOP)}M${pt(x0, cy)}A${rr} ${rr} 0 0 0 ${pt(ex, ey)}` };
    })(),
    a: (() => {
        const cx = S / 2 + R;
        return {
            width: 2 * R + S,
            d: `M${pt(cx + R, 0.5)}A${f(R)} ${f(R)} 0 1 1 ${pt(cx - R, 0.5)}A${f(R)} ${f(R)} 0 1 1 ${pt(cx + R, 0.5)}` +
               `M${pt(cx + R, TOP)}L${pt(cx + R, BASE)}`,
        };
    })(),
};

const LETTERS: Letter[] = ["e", "m", "i", "r", "a"];

// Each window's width at rest: its letter plus padding, in whole points so the still is crisp.
const REST_WIDTH = Object.fromEntries(
    LETTERS.map((l) => [l, Math.round(GLYPHS[l].width * X_HEIGHT + 2 * PAD_X)]),
) as Record<Letter, number>;

// The `e`'s left edge: where it sits when the whole word is centred, and where it stays.
const ORIGIN_X = (WIDTH - (LETTERS.reduce((w, l) => w + REST_WIDTH[l], 0) + COLUMN_GAP * (LETTERS.length - 1))) / 2;
const ORIGIN_Y = (HEIGHT - WINDOW_HEIGHT) / 2;

// --- Layout --------------------------------------------------------------------------------------
// A strip is columns of windows plus a focus, and each step is a function from one to the next.

interface Column { width: number; windows: Letter[] }
interface Strip { columns: Column[]; focus: Letter | null }

const restStrip = (): Strip => ({
    columns: LETTERS.map((l) => ({ width: REST_WIDTH[l], windows: [l] })),
    focus: null,
});

function apply(strip: Strip, step: Step): Strip {
    const next: Strip = { columns: strip.columns.map((c) => ({ ...c, windows: [...c.windows] })), focus: strip.focus };
    if (step.focus !== undefined) next.focus = step.focus;
    const at = next.columns.findIndex((c) => next.focus !== null && c.windows.includes(next.focus));
    const focus = next.focus!;
    if (step.resize) next.columns[at].width += step.resize;
    if (step.move) {
        const to = at + step.move;
        [next.columns[at], next.columns[to]] = [next.columns[to], next.columns[at]];
    }
    if (step.consume) {
        const into = next.columns[at + step.consume];
        into.windows.push(focus);
        into.width = Math.max(into.width, next.columns[at].width);
        next.columns.splice(at, 1);
    }
    if (step.expel) {
        const from = next.columns[at];
        from.windows = from.windows.filter((l) => l !== focus);
        from.width = Math.max(...from.windows.map((l) => REST_WIDTH[l]));
        next.columns.splice(at + (step.expel > 0 ? 1 : 0), 0, { width: REST_WIDTH[focus], windows: [focus] });
    }
    if (next.columns[0].windows.join() !== "e") throw new Error(`"${step.label}" moves the e, or puts something before it`);
    return next;
}

// Every window's rect and opacity: the values the spring animates.
const PROPS = ["x", "y", "w", "h", "o"] as const;
type Prop = (typeof PROPS)[number];
type Placement = Record<Letter, Record<Prop, number>>;

function place(strip: Strip): Placement {
    const out = {} as Placement;
    let x = ORIGIN_X;
    for (const column of strip.columns) {
        const n = column.windows.length;
        const h = (WINDOW_HEIGHT - WINDOW_GAP * (n - 1)) / n;
        column.windows.forEach((l, i) => {
            const lit = strip.focus === null || strip.focus === l;
            out[l] = { x, y: ORIGIN_Y + i * (h + WINDOW_GAP), w: column.width, h, o: lit ? 1 : UNFOCUSED_OPACITY };
        });
        x += column.width + COLUMN_GAP;
    }
    return out;
}

// --- Timeline ------------------------------------------------------------------------------------
// Each step retargets every value; the spring carries position *and* velocity across, so a step that
// lands before the last has settled bends the motion instead of restarting it. Critically damped has
// a closed form, so any instant is exact — nothing is integrated, and no frame depends on how many
// came before it.

interface Timed { t: number; step: Step; strip: Strip; target: Placement }

const STEPS: Timed[] = (() => {
    let strip = restStrip();
    let t = 0;
    return SCRIPT.map((step) => {
        strip = apply(strip, step);
        const timed = { t, step, strip, target: place(strip) };
        t += step.hold;
        return timed;
    });
})();

export const DURATION = STEPS.at(-1)!.t + STEPS.at(-1)!.step.hold;

type Motion = Record<Letter, Record<Prop, { x: number; v: number }>>;

// Displacement d from the target and velocity v, `dt` seconds on.
function spring(d: number, v: number, dt: number) {
    const b = v + OMEGA * d;
    const e = Math.exp(-OMEGA * dt);
    return { d: (d + b * dt) * e, v: (v - OMEGA * b * dt) * e };
}

function advance(motion: Motion, target: Placement, dt: number): Motion {
    const out = {} as Motion;
    for (const l of LETTERS) {
        out[l] = {} as Motion[Letter];
        for (const p of PROPS) {
            const { x, v } = motion[l][p];
            const r = spring(x - target[l][p], v, dt);
            out[l][p] = { x: target[l][p] + r.d, v: r.v };
        }
    }
    return out;
}

// What each step starts from: every value and its velocity, carried forward from the one before.
const STARTS: Motion[] = (() => {
    const settled = {} as Motion;
    for (const l of LETTERS) {
        settled[l] = {} as Motion[Letter];
        for (const p of PROPS) settled[l][p] = { x: STEPS[0].target[l][p], v: 0 };
    }
    const starts = [settled];
    for (let i = 1; i < STEPS.length; i++) {
        starts.push(advance(starts[i - 1], STEPS[i - 1].target, STEPS[i].t - STEPS[i - 1].t));
    }
    return starts;
})();

const wrap = (t: number) => ((t % DURATION) + DURATION) % DURATION;

/** The step in force at `t`, and its index in the script. */
export function stepAt(t: number): Timed & { index: number } {
    t = wrap(t);
    let index = STEPS.length - 1;
    while (index > 0 && STEPS[index].t > t) index--;
    return { index, ...STEPS[index] };
}

/** How far the loop's end is from its start, in points — 0 when it closes seamlessly. */
export function seam(): number {
    const last = STEPS.length - 1;
    const end = advance(STARTS[last], STEPS[last].target, STEPS[last].step.hold);
    return Math.max(...LETTERS.flatMap((l) => PROPS.map((p) => Math.abs(end[l][p].x - STEPS[0].target[l][p]))));
}

// --- Drawing -------------------------------------------------------------------------------------

// A letter's size in a window: its rest size, or smaller when the window can't hold that — a narrow
// column, a stacked half. Padding gives way first, so a letter shrinks only once the margin is spent.
function letterScale(letter: Letter, w: number, h: number): number {
    const padX = Math.min(PAD_X, w * 0.18);
    const padY = Math.min(PAD_Y, h * 0.12);
    const reach = Math.max(GLYPH_TOP - ANCHOR, ANCHOR);
    return Math.max(0, Math.min(X_HEIGHT, (w - 2 * padX) / GLYPHS[letter].width, (h / 2 - padY) / reach));
}

function windowSVG(letter: Letter, { x, y, w, h, o }: Record<Prop, number>): string {
    const g = GLYPHS[letter];
    const k = letterScale(letter, w, h);
    const gx = x + (w - g.width * k) / 2;
    const gy = y + h / 2 + ANCHOR * k;            // the baseline, in y-down canvas space
    const r = Math.min(RADIUS, w / 3, h / 3);
    const dot = g.dot ? `<circle cx="${f(g.dot[0])}" cy="${f(g.dot[1])}" r="${DOT_R}" fill="${INK}" stroke="none"/>` : "";
    return `<g opacity="${f(Math.min(1, Math.max(0, o)))}">` +
        `<rect x="${f(x)}" y="${f(y)}" width="${f(w)}" height="${f(h)}" rx="${f(r)}" fill="url(#window)" filter="url(#shadow)"/>` +
        `<g transform="translate(${f(gx)} ${f(gy)}) scale(${f(k)} ${f(-k)})" fill="none" stroke="${INK}" ` +
        `stroke-width="${S}" stroke-linecap="round" stroke-linejoin="round"><path d="${g.d}"/>${dot}</g></g>`;
}

const DEFS =
    `<defs>` +
    `<linearGradient id="window" x1="0" y1="0" x2="0" y2="1">` +
    `<stop offset="0" stop-color="${WINDOW_TOP}"/><stop offset="1" stop-color="${WINDOW_BOTTOM}"/></linearGradient>` +
    `<filter id="shadow" x="-30%" y="-30%" width="160%" height="160%">` +
    `<feDropShadow dx="0" dy="1.5" stdDeviation="2.5" flood-color="#000" flood-opacity="0.22"/></filter>` +
    `</defs>`;

/** The picture `t` seconds into the loop, as a standalone SVG document. */
export function frame(t: number, { scale = 1 } = {}): string {
    const { index, strip } = stepAt(t);
    const motion = advance(STARTS[index], STEPS[index].target, wrap(t) - STEPS[index].t);
    // The focused window draws last, so one moving past its neighbour passes over it.
    const order = [...LETTERS].sort((a, b) => Number(a === strip.focus) - Number(b === strip.focus));
    const windows = order.map((l) => {
        const at = Object.fromEntries(PROPS.map((p) => [p, motion[l][p].x])) as Record<Prop, number>;
        return windowSVG(l, at);
    });
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH * scale}" height="${HEIGHT * scale}" ` +
        `viewBox="0 0 ${WIDTH} ${HEIGHT}">${DEFS}${windows.join("")}</svg>`;
}
