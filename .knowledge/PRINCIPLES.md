# emira — a scrollable-tiling window manager for macOS

A **Swift**-based scrollable-tiling window manager for macOS, inspired by
**[niri](https://github.com/YaLTeR/niri)**. This document captures the project's identity and — most importantly —
the architectural direction for the hard problem: **moving windows smoothly, without touching SIP.**

---

## 1. What we're building

The model:

- **An infinite horizontal strip of columns.** Windows live in columns arranged left-to-right on a conceptually
  infinite ribbon. You scroll the ribbon left/right to bring columns into view.
- **Columns hold one or more windows** stacked vertically, with cyclable preset widths. Windows never overlap.
- **Dynamic workspaces**, per-monitor (GNOME-style dynamic, not fixed slots).
- **Buttery animations are the aspiration.** Smooth scrolling and window motion are what make a strip feel alive —
  niri is the proof of that. On macOS it is the hard part, because — unlike a Wayland compositor — **we do not own the
  pixels.** Each app renders its own window; we can only ask apps (slowly, over the Accessibility API) to move/resize,
  or composite screenshots of them in windows we own.

If placement isn't instant and correct, we've failed. If we can _also_ make the signature scroll feel smooth, we've
won.

---

## 2. The core decision: SIP stays ON (the AeroSpace philosophy)

**This project keeps System Integrity Protection fully enabled and uses no private/undocumented system APIs, no code
injection, and no scripting addition.** We are deliberately modeling ourselves on
**[AeroSpace](https://github.com/nikitabobko/AeroSpace)**, not [yabai](https://github.com/koekeishiya/yabai).

Why this is load-bearing (not just a preference):

- **Adoption & trust.** Requiring users to disable SIP is a hard sell and a security downgrade. Staying SIP-on means
  "download and run," survives OS updates, and never bricks on a macOS security change.
- **It sets the ceiling on what's possible, and we accept that ceiling.** With SIP on we **cannot**: transform another
  app's live surface, set another app's window alpha/level, hide a foreign window, or drive Spaces via private calls.
  Everything below is designed to deliver the _feel_ we're after within these limits rather than fighting them.

> **Terminology, stated once so we never flip it again:** SIP _enabled_ ("on") is the default, protected state — and
> it is the state we require. Disabling SIP is what yabai-style SkyLight/Dock-injection needs; **we are explicitly
> not doing that.** "SIP on" here means _maximum_ protection, _minimum_ privilege.

**What we're allowed to use:** the public Accessibility API (`ApplicationServices`), our own `AppKit` windows,
**ScreenCaptureKit** for capturing window images, `CADisplayLink` for animation timing, and Core Animation for our
own overlay layers. That's the whole toolbox.

---

## 3. The two-plane mental model

The single most important idea in this codebase. A window "moving" is two independent things:

| Plane                  | Mechanism                                                                                                               | Speed                       | Owns                                                   |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------- | --------------------------- | ------------------------------------------------------ |
| **Truth plane**        | Accessibility API (`AXUIElementSetAttributeValue`)                                                                      | Slow, app-main-thread-bound | Authoritative geometry, focus, window lifecycle events |
| **Presentation plane** | **A layered reconstruction of the desktop** (wallpaper + per-window layers) in overlays we own, fed by ScreenCaptureKit | Instant, GPU compositor     | What the user sees _during a transition_               |

- The **truth plane** is where a window _really is_. Reliable, but latency is dictated by the target app's main run
  loop — a busy Chrome/IntelliJ services us whenever it gets around to it. We cannot fix this. The _median_ teleport
  is nearly free (**max 14 ms observed** across several windows including a sometimes-slow Chrome); the cover's real
  value is masking the rare tail stall, which is cheap insurance rather than a constant tax.
- The **presentation plane** is made of **windows we own**, so we can translate/scale/fade/cross-fade their contents
  at refresh rate with zero foreign-app involvement. The key move (see §4b): don't hold _one flat screenshot_ — hold a
  **layered reconstruction** of the desktop (a wallpaper layer at the bottom, one layer per window on top), so each
  window can be animated independently while the whole thing stays opaque and gap-free.

**Strategy: rearrange instantly on the truth plane; smooth it over with a layered reconstruction on the presentation
plane when a transition warrants it.** This is the inverse of the SIP-off design — there we'd transform live foreign
surfaces; here we rebuild the desktop out of pieces we own and puppet those.

### The cost-floor asymmetry (internalize this)

- A pure **move** needs no new pixels → maskable with a screenshot.
- A **resize** requires the app to re-lay-out and redraw → **only the owning app can produce those pixels.** No trick
  removes this floor; we can only cross-fade a scaled screenshot to hide the reflow.

### The infinite strip _is_ off-screen stashing

The ribbon maps perfectly onto AeroSpace's core technique: **windows live at absolute positions on an infinite
horizontal axis; only a viewport-worth is on-screen; everything else is parked off-screen.** "Scrolling the strip" is
just repositioning windows via AX so a different slice enters the viewport. Workspaces are further-off regions of the
same off-screen space. This means **we never touch native macOS Spaces** (whose animations we can't control) — we
emulate them by parking windows off-screen, exactly like AeroSpace. Build the whole layout engine on absolute
virtual-strip coordinates.

---

## 4. Window movement — what actually works under SIP-on

### 4a. The default: instant, correct placement (ship this first)

For most operations — new window, close, retile — **just set the AX geometry and don't
animate.** AeroSpace ships essentially no foreign-window flight animation and feels great because placement is
_immediate and correct_. This is the floor of the product and it must be rock-solid before any animation work.

- Teleport via `AXUIElementSetAttributeValue` (`kAXPositionAttribute` / `kAXSizeAttribute`), off the main thread, per
  §5 hygiene.
- Parking a window "off-screen" = **sliver-parking**. macOS will not let a window leave the screen entirely: ask for
  an *extreme* off-screen coordinate and it clamps to a ~40 px sliver in every direction (the top is fully blocked by
  the menu bar). But that clamp is **not a floor** — a *precise* position leaving ~1 px on screen is honored. So a
  parked window sits at a unique, staggered slot hugging the working area's bottom-left corner, showing a
  ~1 × 40 pt nub. Slots are computed by the layout engine like any other target geometry — deterministic and unique,
  which keeps parked windows warm, keeps frames distinct for identity binding (§7), and stays out from under the Dock.
- **Because parked windows can't fully hide, they stay warm.** Occlusion is binary: any visible pixel makes a window
  `.visible` and its app keeps rendering. A window parked with a sliver showing kept drawing live video content over a
  3 s park. This inverts the risk the off-screen model was expected to carry — the danger was never "off-screen
  windows freeze", it is that macOS won't let a window leave the screen — and it is likely why AeroSpace flashes when
  revealing a fully-hidden frozen window with no cover, while we shouldn't.
- **Externally-initiated focus is first-class.** Cmd-Tab, a Dock click, or an app activating itself can land focus on
  a parked window — the user must never be "focused" on something they can't see. We observe activation
  (`NSWorkspace`) and AX focus changes, and **snap** the viewport to reveal the newly focused window. No cover, no
  animation: we didn't initiate the motion, so there's no smoothness promise to keep. (An animated-reveal toggle can
  come later.)

### 4b. The smoothness layer: a layered desktop reconstruction

Cover the whole screen so nothing is exposed — but make the cover **layered**, not flat, so we can still move each
window independently. This is the best of both: no exposure _and_ per-window motion. We stand up a throwaway
mini-compositor, animate in it, and cross-fade back to the real desktop.

1. **Capture pieces, not a picture.** Grab the wallpaper once, and each relevant window as its **own** image
   (ScreenCaptureKit's window filter captures a window's surface even when it's occluded). Synthesize window shadows
   ourselves (`CALayer` shadow props) — the system drop-shadow isn't part of the window surface.
2. **Build the reconstruction.** In a borderless overlay we own (per display), composite: wallpaper layer at the
   bottom, one `CALayer` per window on top, each positioned to match reality _exactly_ (backing scale, color space,
   frame). Raise it — it's now a pixel-identical, fully opaque, gap-free stand-in for the desktop.
3. **Rearrange the real windows behind it, freely.** Because the reconstruction hides _everything_, we can teleport
   all real windows to their new AX positions with **zero exposure** — no per-window flight problem, no ordering
   dance.
4. **Animate the layers, however we like.** Slide the window layers to scroll the strip, at independent rates, with
   easing, on a `CADisplayLink`. Real per-window motion, not a sliding photograph.
5. **Wait for truth to land, then cross-fade out.** Hold the reconstruction until the real windows have actually
   arrived at their AX targets (observe + poll), bounded by a ~1 s hold-timeout (then reveal truth and reconcile;
   `IMPLEMENTATION.md` §3). _This is a feature:_ the overlay masks slow AX placement — a busy Chrome/JVM window can
   take its time teleporting while the user sees only our smooth layers. Cross-fade to the real desktop once they're
   aligned.

> **This is proven, not hoped for.** A reconstruction of a single window raised over the real thing is
> imperceptible — "confusingly good" — and the one visible gap, the missing window shadow, is closed by
> synthesizing a per-layer `CALayer` drop shadow that travels with the window. The full loop (opaque cover →
> hidden AX teleport → ghost-free slide → wait-for-AX → cross-fade reveal) reads as indistinguishable from native,
> and visibly smoother than AeroSpace, whose window-switch **flashing** is exactly the artifact the cover
> eliminates. Up to three windows pan in perfect lockstep under one cover, all reals teleporting behind it, with a
> single seamless reveal. Overlay appear-pop is killed with `animationBehavior = .none` plus keeping the overlay
> ordered-in at `alpha 0`, so a raise is a pure alpha flip.

> **Why this beats both a flat cover and per-window overlays.** A flat cover can't do per-window motion (it's one
> photo). Gappy per-window overlays expose the real windows (we can't hide them without SkyLight). A **full, opaque,
> layered** reconstruction has neither flaw: it covers everything (no exposure) yet moves in parts (real animation).

**The residual tradeoff — content freshness.** Each window layer is a _snapshot_, so its content (not its motion) is
frozen for the transition's duration (~150–400ms). Two ways to handle it:

- **Static snapshots (default).** Simple, cheap. Content frozen during motion, live again the instant we cross-fade
  back. Fine for essentially all discrete commands.
- **Live layers (deluxe).** Feed each window layer from a _live_ ScreenCaptureKit stream instead of a still, so video
  keeps playing and cursors keep blinking _while_ the layers animate. Removes the freeze even for a long continuous
  drag. Cost: one live stream per visible window (keep it to a handful) plus ~1 frame of stream latency — invisible
  under motion, erased on cross-fade. This is the true have-cake-and-eat-it path.

### 4c. Interactive/continuous gestures

The layered reconstruction (§4b) makes continuous trackpad scrolling tractable: raise it on gesture-begin, move the
window layers with the finger, reconcile the real windows on release, cross-fade back. Motion is always smooth; the
only open question is content freshness during the drag:

- **Static layers (start here).** Content frozen for the duration of the drag, live again on release. Cheap and
  robust; for scrolling past windows it reads fine.
- **Live layers (upgrade).** Per-window ScreenCaptureKit streams keep content playing during the drag (§4b deluxe).
  Reach for this only if static-during-drag feels off.
- **Avoid throttled live AX repositioning** as a baseline — it depends on every on-screen app being responsive and
  falls apart on a busy Chrome/JVM window. The whole point of the reconstruction is to not need that.

Start with **static layers, reconcile-on-release**; escalate to live layers if the freeze is noticeable.

### 4d. Resize

Real size is app-bound. Set it via AX; if the reflow is visibly janky, cross-fade a scaled screenshot over it until
the app redraws (observe `kAXWindowResizedNotification`, poll fallback). Accept a brief soft frame on heavy apps.

---

## 5. AX hygiene (do this or apps will feel broken)

Much of the "slow AX" pain is self-inflicted and controllable:

- **Minimize AX footprint.** Chromium/Electron and JVM (JetBrains) apps spin up a _heavyweight_ accessibility engine
  the moment an AX client touches their tree, which slows the whole app — often the real cause of the pauses. **Only
  fetch window-level elements. Cache `AXUIElementRef`s. Never walk the child tree. Don't re-query what you can
  observe.**
- **The `kAXEnhancedUserInterface` bug.** When on (Chromium/Electron enable it), `setFrame` gets animated and
  positions come out offset/wrong. Toggle it **off** immediately before a set and restore after — what Rectangle and
  yabai both do.
- **Never block our own run loop.** AX setters are synchronous Mach IPC. Run them off the main thread on a **serial
  per-app queue**, with a short `AXUIElementSetMessagingTimeout` so a hung app can't stall the WM (protects _us_;
  doesn't make the app faster).
- **Observe, don't poll.** Use `AXObserver` for moved/resized/created/destroyed — but budget for apps that emit late
  or not at all, so keep a poll fallback.
- **Expect clamping.** Apps clamp to min/max/constraints; you may need size → position → size again to land exactly.

---

## 6. Fundamental constraints (truths, not bugs)

- **We cannot hide, alpha, transform, or re-level a foreign window.** Those need SkyLight (SIP-off). All masking must
  be done with covers made of our own overlay windows. This is _the_ constraint that shapes §4.
- **Resized content must come from the app.** The floor on resize smoothness is the app's own responsiveness.
- **macOS will not let a window go fully off-screen.** Extreme coordinates clamp to a ~40 px sliver; precise ones
  leave as little as ~1 px. The consequence is §4a's sliver park, and the compensation is that a window which cannot
  hide cannot be throttled for being hidden.
- **ScreenCaptureKit needs Screen Recording permission** (TCC) — a normal user grant, no SIP change. Budget for the
  onboarding prompt. macOS also **periodically re-prompts** users to keep allowing screen capture; under our charter
  nothing can be done about it — accept it, and set expectations in onboarding copy.
- **Snapshot layers freeze _content_, never motion.** With static layers a window's _content_ is frozen during a
  transition (its movement is always smooth). Live ScreenCaptureKit layers remove even that, at a per-window
  streaming cost. Keep transitions short regardless.
- **Reconstruction fidelity is make-or-break.** The layered overlay must be pixel-identical to the real desktop
  (backing scale, color space, synthesized shadows) or the raise/cross-fade will pop.

---

## 7. Implementation notes (Swift)

- **Why Swift — and why it wasn't a performance call.** Every framework this project leans on — AppKit,
  ScreenCaptureKit, Core Animation, CoreVideo, Accessibility — is Apple's, and the two hardest (SCK, Core Animation)
  are Obj-C, block/delegate/async-heavy. Swift calls all of them natively, with ARC; no `objc_msgSend` plumbing, no
  hand-rolled retain/release. Crucially, this was **not** a speed decision: the hot path is AX Mach IPC (bounded by the
  _target app's_ main thread) and the GPU compositor (Core Animation's render server) — **there is no CPU-bound kernel
  anywhere in this app**, so language codegen doesn't discriminate on smoothness (AX latency is masked by Core
  Animation, not by fast arithmetic). The real axis was **interop ergonomics + prior-art leverage**:
  AeroSpace, Amethyst, and Rectangle (§8) — the three references doing our _exact_ SIP-on AX task — are all Swift, so
  the copy-pasteable patterns (enhanced-UI toggle, clamping dance, off-screen parking, enumeration) already live in
  Swift.

- **Architecture: pure core + thin shell + CLI over a socket. Put the one language boundary at the socket, never in
  the animation loop.**
  - **Pure core (framework-free).** The layout engine (virtual-strip coords, column widths) and the reconciliation
    state machine, expressed as `events → intents` over value types and exhaustive `enum`s. No AppKit import;
    unit-testable in isolation. This is the rigorous heart, and it'd be clean in _any_ language — so it isn't the
    tiebreaker.
  - **Thin imperative shell.** Binds the core to CA / AX / SCK. Big and Obj-C-entangled by nature — exactly where
    Swift's nativeness pays continuously and an FFI layer would tax every call.
  - **CLI = thin socket client.** `emira <verb> …` parses args and speaks a small JSON/line protocol over a
    Unix-domain socket to the long-running daemon, which does the work (the yabai/aerospace model). The socket is also
    the _one_ clean polyglot seam if a different-language CLI is ever wanted — near-zero framework coupling, a trivial
    wire contract.

- **The core owns the clock; the shell is a dumb blitter.** We deliberately do _not_ let Core
  Animation tween the window stand-ins. Instead the **pure core** holds each animated element's `{current, velocity,
  target, curve}` and is advanced by a display-link `tick(dt)` event; it emits explicit per-frame `setLayerFrame`
  intents that the shell blits via `layer.position` inside a `CATransaction` with actions disabled. This _inverts_ the
  old "read `layer.presentationLayer`, kill the in-flight `CAAnimation`, restart from the presented value" dance:
  because the core never surrenders the position, **retargeting mid-flight — move a window, move it back, grab another,
  all before the first lands — is just arithmetic (set a new target, carry the velocity)**, and it is fully
  unit-testable off a scripted event stream with synthetic `dt`, with zero CA or AX in the test. Spring velocity
  carryover on interrupt is also what makes the motion feel alive — and `CASpringAnimation` _can't_ be cleanly
  retargeted with preserved velocity, so this isn't only cleaner, it's closer to correct. The daemon still stays in the
  framework language, but for the _other_ couplings — AX Mach IPC, ScreenCaptureKit, the overlay/compositor, and the
  display-link driver — **not** because the reconciler needs Core Animation. (See `IMPLEMENTATION.md` for the full
  event → reduce → effect shape.)

- **Platform floor: macOS 26 "Tahoe".** Greenfield with no users — take the newest floor and use
  the current API surface everywhere: `CADisplayLink` (`NSScreen.displayLink`) unconditionally, the modern
  ScreenCaptureKit throughout, no availability checks, no legacy paths. Revisit only for a concrete tester need, never
  speculatively.

- **Concurrency: `@MainActor` pins the animation state; AX IPC is the only thing off-thread.** Core Animation is
  main-thread, so the reconciliation state is main-thread-pinned by construction — mark it `@MainActor` and let Swift
  6 strict-concurrency checking _prove_ at compile time that nothing mutates it off-thread (this directly guards the
  "mutated mid-reconcile from the wrong thread" bug class). The only real concurrency is the AX boundary: setters and
  observers run off the main thread on **serial per-app queues** (GCD), with results marshaled explicitly back to the
  main actor. Capture runs on its own queue; all overlay/animation work on the main thread.

- **Memory: ARC for the Cocoa graph; CF bridging at the edges.** `NSWindow`/`CALayer`/Swift objects are ARC-managed.
  The C/CoreFoundation handles — `AXUIElement`, `CGImage`, `CVPixelBuffer`/`IOSurface` — bridge via
  `takeRetainedValue()` / `takeUnretainedValue()`; get the +1 vs +0 ownership right at each boundary.

- **No private symbols.** By policy we do not link or `dlopen` `SkyLight`, and we avoid private AX SPI — in particular
  the private `_AXUIElementGetWindow`. Instead, window identity is **bound once, at first sight**: the shell matches an
  AX window to its `SCWindow` by **pid + frame + title** at a moment when frames are essentially always unique, then
  keys on the stable public `CGWindowID` (`SCWindow.windowID`) forever after — immune to later frame/title collisions
  (titles are unstable; parked frames would otherwise collide). Unique park slots (§4a) keep even cold-start
  rebinding — a daemon restart with windows already parked — unambiguous.
- **Linking:** `ApplicationServices` (AX — a C API, imports cleanly), `AppKit`/`Cocoa` (overlay windows, run loop),
  `ScreenCaptureKit` (capture), `QuartzCore` (Core Animation layers; `CADisplayLink` via `NSScreen.displayLink` — the
  macOS 26 floor means no `CoreVideo`/`CVDisplayLink` fallback to carry).
- **Overlays are `CALayer`-backed borderless `NSWindow`s** we own — click-through, high window level, one per display
  (or one full-strip layer). All animation is Core Animation / display-link interpolation on _our_ layers.

---

## 8. Related implementations

- **[AeroSpace](https://github.com/nikitabobko/AeroSpace)** — our closest sibling and philosophical model: SIP-on,
  public APIs only, off-screen workspace stashing, instant placement. Study its window enumeration, off-screen
  parking, and how it deliberately _doesn't_ animate foreign windows.
- **[niri](https://github.com/YaLTeR/niri)** — where the scrollable-tiling model comes from, and our north star for _feel_: an inspiration, not a specification.
- **[yabai](https://github.com/koekeishiya/yabai)** — the counter-example: what smooth foreign-window control looks
  like _with_ SkyLight/SIP-off. Read it to understand precisely what we're giving up by staying SIP-on.
