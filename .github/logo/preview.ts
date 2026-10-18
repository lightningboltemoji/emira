// The loop, live, on a light page and a dark one — the same `frame(t)` the renderer rasterizes, so
// what plays here is what the webp will be, give or take the frame rate.

import { DURATION, FPS, SCRIPT, frame, stepAt } from "./scene.ts";

const $ = <T extends HTMLElement>(selector: string) => document.querySelector<T>(selector)!;
const stages = document.querySelectorAll<HTMLElement>(".stage");
const play = $<HTMLButtonElement>("#play");
const scrub = $<HTMLInputElement>("#scrub");
const time = $<HTMLSpanElement>("#time");
const speed = $<HTMLSelectElement>("#speed");
const list = $<HTMLOListElement>("#steps");

let t = 0;
let playing = true;
let last = performance.now();

scrub.max = String(DURATION);

const starts = SCRIPT.map((_, i) => SCRIPT.slice(0, i).reduce((at, s) => at + s.hold, 0));
const buttons = SCRIPT.map((step, i) => {
    const item = document.createElement("li");
    const button = document.createElement("button");
    button.textContent = step.label;
    button.onclick = () => { t = starts[i]; draw(); };
    item.append(button);
    list.append(item);
    return button;
});

function draw() {
    const svg = frame(t, { scale: 2 });
    for (const stage of stages) stage.innerHTML = svg;
    scrub.value = String(t);
    time.textContent = `${t.toFixed(2)}s`;
    const { index } = stepAt(t);
    buttons.forEach((b, i) => b.classList.toggle("current", i === index));
}

function setPlaying(on: boolean) {
    playing = on;
    play.textContent = on ? "pause" : "play";
}

function tick(now: number) {
    if (playing) t = (t + ((now - last) / 1000) * Number(speed.value)) % DURATION;
    last = now;
    draw();
    requestAnimationFrame(tick);
}

play.onclick = () => setPlaying(!playing);
scrub.oninput = () => { setPlaying(false); t = Number(scrub.value); };
document.addEventListener("keydown", (event) => {
    if (event.key === " ") { event.preventDefault(); setPlaying(!playing); }
    if (event.key === "ArrowRight" || event.key === "ArrowLeft") {
        setPlaying(false);
        t = (t + (event.key === "ArrowRight" ? 1 : -1) / FPS + DURATION) % DURATION;
    }
});

requestAnimationFrame(tick);
