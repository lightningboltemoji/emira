# emira — Implementation Plan

**Companion to `PRINCIPLES.md`.** `PRINCIPLES.md` is the *why* — the SIP-on charter, the two-plane model, and the
graphics thesis. This document is the *how*: the module layout, the shape of the pure core, the shell subsystems a
mature emira contains, and the order we build them in. Where the two disagree, `PRINCIPLES.md` wins on principle and
this doc gets corrected. (`CLAUDE.md` is a thin pointer at both, so agent sessions auto-load the charter.)

Guiding bias, restated: **stay small.** emira should read like AeroSpace-sized software, not a platform. Every
subsystem below earns its place or gets cut. The roadmap (§9) marks the milestone (**M5**) at which emira is a
complete, lightweight product; everything past it is optional polish.

---

## 1. The architectural spine

**Functional core, imperative shell — and the core owns the clock.**

emira is one pure reducer wrapped in a thin macOS shell:

```
                    ┌──────────────────────────────────────────────────┐
   Events  ───────► │            EmiraCore  (pure, no AppKit)           │ ──────► Effects
                    │                                                   │
  · CLI command     │   reduce(State, Event) -> (State, [Effect])       │   · setFrame(win, rect)   [AX]
  · hotkey command  │                                                   │   · park(win)             [AX]
  · AX observation  │   State = World (truth) + Layout + Motion         │   · setLayerFrame(id,rect)[CA]
  · display tick dt │            + Config                               │   · capture(win)          [SCK]
  · IPC / config    │                                                   │   · raiseCover / crossFade
                    └──────────────────────────────────────────────────┘   · focus(win) / raise(win)
                             ▲                              │
                             │ feedback events              │ executed by
                             │ (axLanded, captureReady,     ▼
                             │  crossfadeDone, axFailed)   EmiraShell  (AppKit / AX / SCK / CA)
```

Four invariants hold this together. They are the whole design:

1. **`EmiraCore` imports no framework.** Foundation-only. If a thing can't be a value type or an exhaustive `enum`, it
   lives in the shell. This is what makes the brain unit-testable in isolation.
2. **The core owns animation time.** We do *not* use `CAAnimation` tweening. The core holds `{current, velocity,
   target, curve}` for every animated element and advances them on `Event.tick(dt)`; the shell just blits
   `layer.position` each frame. Retargeting mid-flight is therefore pure arithmetic (new target, keep velocity), not a
   `presentationLayer`/`CAAnimation` teardown. This is the decision from `PRINCIPLES.md` §7.
3. **Effects can fail, and failure is just another event.** Every Effect the shell executes may feed a result back in
   (`axLanded`, `axFailed`, `captureReady`, `crossfadeDone`). The core stays *total* — exhaustive over every event —
   so a hung app or a vanished window is a normal transition, not a crash.
4. **The pump is never re-entrant.** `dispatch()` during an active pump **appends to a FIFO queue and returns**;
   `reduce` never runs inside `reduce`, and event A's effects are fully issued before event B reduces. macOS makes
   accidental recursion easy — `orderFront` fires delegate notifications synchronously, an AX call can complete on the
   calling thread — so any handler that produces an event must enqueue it, never dispatch inline. This costs nothing
   (the queued event still runs in the same run-loop turn, against a consistent state) and does **not** limit
   interruption/retargeting, which happens *between* pumps, never inside one.

Everything else in this document is a consequence of these four.

---

## 2. The command vocabulary (one source of truth)

There is exactly **one** list of "things you can ask emira to do": `Command`. It is defined once in `EmiraCore` and
reused by every surface, so a new verb is added in one place:

- the **CLI** parses `argv` into a `Command` and sends it over the socket;
- the **hotkey manager** maps a key combo to a `Command`;
- the **config file** binds keys and window-rules to `Command`s;
- the **wire protocol** is `Command` (Codable) in an envelope;
- the **core** consumes it as `Event.command(Command)`.

```swift
enum Command {
    case focus(Direction)            // left/right/up/down
    case moveWindow(Direction)
    case moveToWorkspace(WorkspaceRef)
    case cycleWidth                  // preset column widths
    case cycleHeight
    case consumeOrExpel(Direction)   // pull a window into / push out of the column
    case fullscreen(Toggle)
    case float(Toggle)
    case focusWorkspace(WorkspaceRef)
    case closeWindow
    case centerColumn
    case dumpState                   // introspection for `emira debug`
    // …grows here, and only here.
}
```

Keeping this in the pure core (not the protocol layer) means the reducer, the tests, and the CLI all speak the same
type with no translation. `EmiraProtocol` only wraps it for the wire.

---

## 3. Data flow & the transition lifecycle

**Steady state has no overlay.** In the resting state the real windows simply sit at their AX positions; the
presentation plane does not exist. A cover/reconstruction is *ephemeral* — it goes up only for the duration of a
transition and comes down on cross-fade. The Runtime therefore has two modes, and the core drives the switch:

- **Idle.** Commands that produce no motion (e.g. a focus change that doesn't scroll) are executed as direct AX sets —
  snap, no cover. The core emits plain `setFrame` / `focus` effects. **Externally-initiated focus** (Cmd-Tab, Dock
  click, an app activating itself — observed via `NSWorkspace` + AX) takes this same path: snap the viewport to reveal
  the focused window. We made no motion, so we owe no animation.
- **Transition.** A command (or a gesture) that produces motion opens a *transition session*: the core emits
  `beginTransition`, the shell captures + raises the reconstruction, real windows teleport behind it, and from then on
  every `tick(dt)` advances the core's animators and emits `setLayerFrame`. When all animators settle **and** the AX
  targets have landed (`axLanded`), the core emits `endTransition` → the shell cross-fades to the real desktop and
  drops the cover. The `axLanded` wait is **scoped and bounded**: scoped — wait on every window whose start or end
  frame intersects the viewport (a failed park leaves a window squatting in view, so departing windows count; only
  park→park motion is invisible and skippable) — and bounded — a hold-timeout (~1 s, itself just an Event) closes the
  transition regardless: reveal the truth, keep retrying the AX set, reconcile when it lands. A frozen cover is worse
  than a visibly hung app.

The core decides *whether a command warrants a transition* (motion vs snap) and *when the transition is done*; the
shell owns the mechanics of cover/capture/cross-fade. This is the clean seam between "policy" (pure) and "mechanism"
(native).

Continuous gestures (§9, M7) are the same session opened by gesture-begin and closed by gesture-end + settle.

---

## 4. Module / target graph

Four library targets and two executables. Dependencies point strictly upward; nothing below imports a framework.

```
EmiraMotion     pure math — springs, easing curves, the scalar Animator.  (zero deps)
    ▲
EmiraCore       pure — geometry, ids, Command/Event/Effect, State, layout engine,
    │           rules, Config values, the Engine reducer.        (deps: EmiraMotion)
    ▲
EmiraProtocol   Codable request/reply envelope, wire framing, one-shot socket client.
    │                                                            (deps: EmiraCore)
    ▲
EmiraShell      imperative — Runtime, Executor, AX, Capture, Compositor, DisplayLink,
    │           Hotkeys, ConfigLoader, IPC server, MenuBar, Permissions.
    │           (deps: EmiraCore, EmiraProtocol; imports AppKit/QuartzCore/SCK/AX/Carbon)
    ▲
   ├── emira-daemon   executable — NSApplication accessory host that runs the Runtime.
   └── emira          executable — CLI; thin socket client.  (deps: EmiraProtocol + EmiraCore)
```

**Why `EmiraMotion` is its own target and not a folder.** A spring/easing solver is genuinely generic — scalar in,
scalar out, given `dt` — and has nothing to do with columns or AX. Splitting it out keeps the physics honest (it can't
reach into reconciler state) and independently testable (feed ticks, assert convergence and velocity carryover). It's
tiny; if two targets ever feels like one too many we collapse it into `EmiraCore/Animation/`, but the seam is worth
starting with.

**Why the CLI stays at the bottom of the graph.** The CLI must be framework-free and trivially fast to launch. It
parses `argv` into a `Command`, hands it to `SocketClient`, prints the reply. No AX, no CA, no AppKit — and no
`EmiraShell`.

---

## 5. Directory layout

```
emira/
├── Package.swift
├── Makefile                         # build + test
├── CLAUDE.md                        # thin agent pointer at the docs below
├── .knowledge/
│   ├── README.md                    # how this project remembers things
│   ├── PRINCIPLES.md                # charter / why
│   ├── IMPLEMENTATION.md            # this file / how
│   └── changes/                     # one file per change, named by epoch second
├── Resources/
│   └── default-config.toml
├── Sources/
│   ├── EmiraMotion/
│   │   ├── Curve.swift              # easing functions + spring params
│   │   ├── Spring.swift             # critically-damped spring integrator
│   │   └── Animator.swift           # {current, velocity, target}; advance(dt); retarget()
│   ├── EmiraCore/
│   │   ├── Geometry.swift           # own Rect/Point/Size on the virtual strip (not CG*)
│   │   ├── Ids.swift                # WindowId, ColumnId, MonitorId, LayerId
│   │   ├── Command.swift            # §2 — the one vocabulary
│   │   ├── Event.swift              # exhaustive input enum (commands + observations + tick)
│   │   ├── Effect.swift             # exhaustive output enum (AX / CA / SCK / cover intents)
│   │   ├── State/
│   │   │   ├── World.swift          # truth: monitors, apps, windows, focus, managed/floating
│   │   │   └── Motion.swift         # viewport-offset + per-window Animators; the transition session
│   │   ├── Layout/
│   │   │   ├── Layout.swift         # strip → columns → windows; its target geometry
│   │   │   ├── Strip.swift          # infinite-axis math, viewport scroll, centering
│   │   │   ├── Column.swift         # vertical stack, heights
│   │   │   ├── Presets.swift        # cyclable width/height presets, gaps, struts
│   │   │   └── Park.swift           # deterministic unique corner nubs (park = target geometry)
│   │   ├── Rules.swift              # pure predicates over a window's metadata
│   │   ├── Config.swift             # parsed config values (pure data; loading is in Shell)
│   │   └── Engine.swift             # reduce(State, Event) -> (State, [Effect])
│   ├── EmiraProtocol/
│   │   ├── Request.swift            # Command + client metadata + version
│   │   ├── Reply.swift              # ok / error / state dump
│   │   └── Wire.swift               # socket path, framing
│   ├── EmiraShell/
│   │   ├── Runtime.swift            # @MainActor pump: Event -> Engine.reduce -> Executor
│   │   ├── Executor.swift           # protocol interpreting Effects (Live + Mock impls)
│   │   ├── WindowRegistry.swift     # mints WindowIds; binds AX ↔ CGWindowID at first sight
│   │   ├── AX/                      # client, enumerator, observers, enhanced-UI toggle
│   │   ├── Capture/                 # ScreenCaptureKit stills; live streams (M7)
│   │   ├── Compositor/              # overlay windows, the reconstruction, raise/cross-fade
│   │   ├── Display/                 # CADisplayLink -> Event.tick(dt)
│   │   ├── Input/                   # hotkeys; gestures (M7)
│   │   ├── Config/ConfigLoader.swift# locate → read → watch → report
│   │   ├── Ipc/                     # unix-domain socket server + request router
│   │   ├── MenuBar/                 # the whole GUI: an NSStatusItem
│   │   ├── Permissions.swift        # AX + Screen Recording TCC checks + onboarding
│   │   └── Logging.swift            # os_log wrapper
│   ├── emira-daemon/main.swift      # accessory NSApplication; wire up Runtime + subsystems
│   └── emira/main.swift             # argv -> Command -> Request -> socket
└── Tests/
    ├── EmiraMotionTests/            # spring convergence, retarget velocity carryover
    ├── EmiraCoreTests/              # layout math, engine scenarios, golden replays
    ├── EmiraProtocolTests/          # envelope round-trips, framing, version mismatch
    └── EmiraShellTests/             # the pump: FIFO/non-re-entrancy, lifecycle, clock gating
```

---

## 6. What a mature emira contains

Grouped by plane. Items marked *(later)* are post-M5 polish, not part of the lightweight core.

### Pure core (`EmiraMotion` + `EmiraCore`)
- **Motion:** critically-damped spring + easing curves; a scalar `Animator` with `retarget()` that preserves velocity.
  A strip scroll animates **one scalar — the viewport offset** — with layer frames derived from it (lockstep by
  construction, trivial settle-detection, retarget = one number); per-window animators are reserved for genuinely
  independent motion (consume/expel, move-between-columns). The offset scalar is also the natural handle for
  continuous trackpad gestures (M7): the finger drives it directly.
- **Geometry & the strip:** infinite-axis coordinates, column widths/heights, gaps, and **struts** (reserve the
  menu-bar/notch region so tiled windows never sit under it).
- **Layout engine:** columns ↔ windows, preset cycling, scroll/center, per-monitor strips, dynamic workspaces, and
  **park-slot assignment** — deterministic, unique, staggered ~1 × 40 pt nubs in the working area's corner
  (`PRINCIPLES.md` §4a). A park slot is just target geometry, so placement is core-owned: one geometry authority,
  replay-testable, and unique frames keep identity rebinding unambiguous (`PRINCIPLES.md` §7).
- **Rules engine:** pure predicates over window metadata → assign-to-workspace / float / initial-width. Definitions
  come from config; evaluation is pure. Built-in taxonomy defaults: only `AXStandardWindow` tiles;
  dialogs/sheets/panels/popovers float; native-fullscreen windows are excluded (they live on their own Space);
  **minimized and Cmd-H-hidden windows leave the strip** — animated out like a close, strip position remembered,
  re-inserted on return.
- **The `Engine` reducer:** the reconciliation state machine — absorbs external reality (user clicks, app-launched,
  display hotplug) into the World model, decides snap-vs-transition, drives the motion session.

### Imperative shell (`EmiraShell`)
- **Runtime** — the `@MainActor` pump: turn Events into `reduce`, hand Effects to the Executor. The one place the two
  planes meet.
- **AXClient / enumerator / observers / watcher** — the truth plane. Per-app serial queues, messaging timeout,
  enhanced-UI toggle, the clamping dance, window-level-only enumeration (AX hygiene, `PRINCIPLES.md` §5). The same
  source watches `NSWorkspace` activation so externally-initiated focus becomes an Event (snap-reveal), and holds a
  global mouse-up monitor (allowed under the AX grant) marking drag-end so a user-dragged tiled window re-tiles on
  release.
- **Capture** — ScreenCaptureKit stills; live streams *(later)*. Identity comes from `WindowRegistry`: bound once at
  first sight (pid+frame+title at a moment of uniqueness), keyed on the stable public `CGWindowID` thereafter.
- **Compositor** — the layered reconstruction overlays, synthesized shadows, raise/cross-fade.
- **DisplayLinkDriver** — the frame clock; emits `tick(dt)` only while a transition is active (idle = no ticks).
- **Hotkeys** — global binds. The deciding property is not latency, it is **consumption**: an `NSEvent` global monitor
  is already available to us under the AX grant, but it cannot swallow the keystroke, so `alt-h` would scroll the
  strip *and* type into the focused app. A press produces `Event.command` — the same value the CLI sends, so the
  keyboard adds a *surface*, never a code path.
- **ConfigLoader** — TOML parse + watch + hot reload.
- **IPC SocketServer** — the CLI/daemon seam and the introspection endpoint (`dumpState`). Predictable per-user
  socket path with `0600` perms; the wire protocol is versioned from message one (mismatch = graceful CLI error).
- **MenuBar StatusItem** — an accessory (`LSUIElement`, no Dock icon) menu-bar item. This *is* the GUI — no
  preferences window.
- **Permissions** — Accessibility + Screen Recording TCC checks and a first-run onboarding flow.

### Executables
- **`emira-daemon`** — the long-running accessory app that hosts the Runtime and all subsystems.
- **`emira`** — the CLI; `emira focus left`, `emira move-window right`, `emira debug` (pretty-prints the state dump).

### Config (**TOML**, matching AeroSpace)
`~/.config/emira/emira.toml`. The **parsed values** are a pure `Config` struct in `EmiraCore`; the shell owns
**locating, reading and watching**. Covers: keybindings (key → `Command`), gaps, width/height presets, animation
params, window/workspace rules, per-monitor overrides. Struts are deliberately *not* a key — they are read off
`NSScreen.visibleFrame`. Hot-reload emits `Event.configChanged(Config)` — the reducer re-lays-out in place.

---

## 7. Cross-cutting concerns

- **Concurrency.** `@MainActor` pins the Runtime, the Engine state, and all CA/overlay work — Swift 6 strict
  concurrency then *proves* nothing mutates it off-thread. The only off-thread work is AX (serial per-app GCD queues,
  results marshaled back to the main actor) and capture (its own queue). This is exactly `PRINCIPLES.md` §7.
- **No pixels in the core's vocabulary.** `Effect.capture(win)` is answered by `Event.captureReady(win)` — ids, never
  image payloads. The shell owns the image cache keyed by `WindowId`. This keeps `EmiraCore` Foundation-only and keeps
  replay logs small and serializable.
- **Coordinate spaces.** AX and SCK speak top-left-origin global coordinates; Cocoa speaks bottom-left. The Y-flip
  happens exactly once — core geometry is always top-left virtual-strip space and never sees a flipped Y. (Every
  spike hand-rolled this flip; the real codebase does it in one place.)
- **Error & timeout handling.** AX sets have a short messaging timeout; a failure surfaces as `Event.axFailed(win)`
  and the reducer reconciles (retry, or drop the window from layout). A window that vanishes mid-transition is a normal
  event, not an exception. The cover masking slow AX is a *feature*: the user sees smooth layers while a busy app
  teleports on its own schedule.
- **Deterministic replay (a first-class payoff, nearly free).** Because the core is a pure `(State, Event) → (State,
  [Effect])`, we can log every inbound Event and replay the log through a fresh Engine to reproduce any state exactly.
  This gives us: bug repro from a user's session log, regression fixtures (golden Effect streams), and offline
  debugging with zero macOS involved. Build the event log early — it costs almost nothing and pays forever. (At
  120 Hz, `tick` events dominate the log — record them run-length-compressed, or synthesize them on replay.)
- **Observability.** `emira debug` dumps the live `State` as JSON over the socket; structured logging via `os_log`
  behind a small `Logging` wrapper; an optional `EMIRA_TRACE` that appends the event log to disk.

---

## 8. Testing strategy

The architecture exists to make testing cheap. Weight the pyramid accordingly:

- **`EmiraMotionTests`** — feed synthetic `dt` sequences; assert springs converge, don't overshoot past tolerance, and
  that `retarget()` preserves velocity (no visual discontinuity on interrupt).
- **`EmiraCoreTests / LayoutTests`** — strip math, width/height cycling, viewport scroll & centering, gaps/struts,
  multi-monitor placement, park-slot assignment (uniqueness, reuse on unpark), rule evaluation. Pure, fast,
  exhaustive.
- **`EmiraCoreTests / EngineScenarioTests`** — the scenarios that motivated this whole design, written as scripts:

  ```
  moveWindow(A, right); tick×3; focus(right); moveWindow(B, right); tick×N
    → assert: A's animator retargeted from its in-flight position with velocity preserved,
              B animating, exactly one transition session open, correct final targets,
              AX setFrame effects emitted for both, endTransition only after both axLanded.
  ```

  These run with a **`MockExecutor`** that records Effects instead of touching macOS — the entire interrupt/retarget
  brain is verified with no AX, CA, or SCK in sight.
- **`ReplayTests`** — golden event logs → asserted final state / Effect stream; regression guard.
- **Shell** stays deliberately thin so it needs little unit testing; it's exercised by the milestone smoke tests (M2
  visual smoke, then real windows at M3+).

---

## 9. Roadmap — how it evolves from the early days

Each milestone is independently demonstrable. Everything through **M2** is pure Swift with no macOS surface; the brain
is fully trustworthy before a single real window moves.

| # | Milestone | What lands | Demonstrable result |
|---|-----------|-----------|---------------------|
| **M0** | Skeleton | `Package.swift`, targets + executables compiling; one green test | `swift test` passes |
| **M1** | The brain | `EmiraMotion`, geometry, layout engine, `Command`/`Event`/`Effect`, `Engine`; scenario + replay tests | Interrupt/retarget scripts pass headless |
| **M2** | End-to-end pipe (fake) | daemon loop + IPC + CLI + DisplayLink + Overlay driving **fake colored layers** from the core | `emira focus left` slides real pixels for fake windows |
| **M3** | Truth plane | AXClient/enumerator/writer/observers + WindowRegistry + WorldWatcher; instant, correct tiling of **real** windows; snap, no cover; snap-reveal on external focus; taxonomy defaults; drag-end re-tile | AeroSpace-parity: real windows tile & scroll, Cmd-Tab reveals (no animation yet) |
| **M4** | The signature scroll | Capture + Reconstruction + Transition; motion under cover | Compositor-smooth scroll and resize on real windows |
| **M5** | Ergonomics → **lightweight-complete** | ConfigLoader + Hotkeys + MenuBar + Permissions onboarding | Install, grant, edit TOML, drive by keyboard. **Shippable here.** |
| **M6** | Full layout model | Virtual workspaces, per-monitor strips, window/workspace rules, monitor hotplug | Multi-display, multi-workspace daily driver |
| **M7** | Deluxe *(optional)* | Continuous trackpad gestures, live-stream layers, focus-ring overlay, overview/zoom-out | Continuous smooth drag; content live during motion |

**M5 is the line.** A complete emira is M0–M5: it tiles, scrolls smoothly, is keyboard-driven, configurable, and
installs cleanly. M6 makes it a daily driver; M7 is where we chase the last 10% of the feel. If we stop at M5 we still
have shipped the thing.

---

## 10. Non-goals & explicit scope cuts

- **No SIP-off anything, ever.** No SkyLight, no code injection, no scripting additions, no private AX SPI (window identity via
  first-sight binding → public `CGWindowID`, not `_AXUIElementGetWindow`). This is the charter, not a phase.
- **No native Spaces / Mission Control integration.** Workspaces are emulated by off-screen parking (`PRINCIPLES.md` §3).
  We recommend users disable "Displays have separate Spaces," as AeroSpace does.
- **No preferences GUI.** The config file is the UI; the menu bar is the only chrome.
- **No layout persistence across restart.** Re-tile from live window enumeration on launch. (Loose workspace-rule
  reassignment via config is enough.)
- **No foreign-window resize smoothness beyond the app's own speed** — a hard floor (`PRINCIPLES.md` §6); we only cross-fade
  a scaled screenshot over a janky reflow.

---

## 11. Open items

Settle these as we build, not now.

1. **Config format** — TOML (AeroSpace parity) versus something we already parse. Leaning TOML for familiarity.
2. **`EmiraMotion` as a separate target vs a folder** — starting separate for the clean seam; trivial to collapse.
3. **Hotkey mechanism** — the system hotkey registry versus a `CGEventTap`. The registry consumes keystrokes and needs
   no extra grant, so it is the default unless we need combos it can't express.
4. **Real signing** — Developer ID + hardened runtime + notarization, and with them a TCC grant that survives a
   rebuild. Ad-hoc is enough to run locally.
