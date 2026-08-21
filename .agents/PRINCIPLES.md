# emira — a scrollable-tiling window manager for macOS

A **Swift**-based scrollable-tiling window manager for macOS, inspired by
**[niri](https://github.com/niri-wm/niri)**. This document is the _what_ and the _why_: the model, the
charter, the graphics thesis, and what emira owes the person using it. `IMPLEMENTATION.md` is the _how_
— boundaries, loops, invariants.

**The keep/cut test for this file: would changing it change what emira _is_?** Mechanism belongs next door.
The investigation, the rejected alternative and the number that settled an argument belong to `changes/`.

---

## 1. The model

- **An infinite horizontal strip of columns.** Windows live in columns arranged left to right on a
  conceptually infinite ribbon; you scroll the ribbon to bring columns into view.
- **Columns stack windows vertically**, and cycle through preset widths and heights. Windows never overlap,
  and are never clipped to fit.
- **36 workspaces at fixed addresses** — `1`–`9`, then `0`, then `a`–`z`, the order the keys sit in — each its
  own infinite strip, one focused and the rest parked. A fixed address space rather than a GNOME-style dynamic
  one: no creation policy, no deletion policy, nothing to collapse, which is strictly less machinery. Nobody
  counts workspaces from zero on a keyboard-driven window manager; they press the key at the left end of the
  number row, so `1` is the launch address and `0` is the tenth.
- **A window's workspace is _derived_ from the strip holding it.** There is one authority on where a window
  is, and nothing may hold a second opinion about it.

**The order of the two goods.** If placement isn't instant and correct, we've failed. If we can _also_ make
the signature scroll feel smooth, we've won. Everything in §3 is the second win, and none of it may become
load-bearing for the first.

---

## 2. The charter: SIP stays on

**emira keeps System Integrity Protection fully enabled and uses no private system API where load-bearing.**

> **Terminology, stated once so we never flip it again:** SIP _enabled_ ("on") is the default, protected
> state, and it is the state we require. Disabling SIP is what yabai-style SkyLight injection needs.

Why this is load-bearing rather than a preference:

- **Adoption and trust.** Requiring a SIP disable is a hard sell and a security downgrade. Staying SIP-on
  means "download and run", survives OS updates, and never bricks on a macOS security change.
- **It sets the ceiling on what is possible, and we accept that ceiling.** We **cannot** transform another
  app's live surface, set its alpha or window level, hide its window, or drive Spaces privately. Everything
  that follows is designed to deliver the feel we want _within_ those limits rather than fighting them.

**The whole toolbox:** the public Accessibility API, our own AppKit windows, ScreenCaptureKit, and Core
Animation plus the display link on layers we own.

**One private symbol, on stated terms.** The cursor is the sole exception, because no public route lets a
background app hide the pointer at all. It is admitted only because it passes four tests, and any future
exception is held to the same four: it does not touch SIP; it decides nothing about where a window goes, so
failing it costs no correctness; it is reached by name at runtime, so a removed symbol is a `nil` rather than
a binary that won't launch; and it lives in one file that a single commit could delete.

---

## 3. The thesis: two planes

The single most important idea in the project. A window "moving" is two independent things:

| Plane            | Mechanism                                                   | Speed                                       | Owns                                     |
| ---------------- | ----------------------------------------------------------- | ------------------------------------------- | ---------------------------------------- |
| **Truth**        | the Accessibility API                                       | slow, bound to the target app's main thread | where a window really is                 |
| **Presentation** | a layered reconstruction of the desktop, in overlays we own | instant, on the GPU compositor              | what the user sees _during a transition_ |

**Rearrange instantly on the truth plane; smooth it over on the presentation plane when a transition warrants
it.** This is the inverse of the SIP-off design — there you would transform live foreign surfaces; here we
rebuild the desktop out of pieces we own and puppet those.

The reconstruction is **layered, not flat**: a captured base holding the wallpaper, the menu bar and every
window that isn't moving, with one captured still per moving window on top. A flat cover cannot move in parts,
because it is one photograph. Gappy per-window overlays expose the real windows, which we are not allowed to
hide. A full, opaque, layered cover has neither flaw — it covers everything _and_ moves in parts.

Four consequences, and they are the whole design:

- **The cover is made of real pixels, never placeholders.** A coloured rectangle sliding where a window should
  be is worse than no animation at all, which is why there is no placeholder fallback anywhere in emira. Real
  pixels at a position nobody derived are the same lie in a better disguise, so a stand-in the core cannot
  place leaves the screen rather than standing where it was last put.
- **Behind a cover, teleporting is free** — no per-window flight problem, no ordering dance. But "hides
  everything" is a claim about the _display_, not about our own call stack, so nothing may move until the
  display itself says the cover is up. A cover is one display's, so the claim is quantified with it: a
  window may move only once the cover is up on every display it is visible on before or after the move.
- **Covering and animating are separate goods.** The cover answers the AX API's _unreliability_; the springs
  answer its _feel_. A user can want the first without the second, which is why the ladder is `off`, `snap`,
  `smooth`: `snap` buys atomicity — the strip is never seen half-arranged — while animating nothing.
- **The cost-floor asymmetry.** A pure **move** needs no new pixels and is fully maskable. A **resize**
  requires the app to re-lay-out and redraw, and **only the owning app can produce those pixels.** No trick
  removes that floor. All we choose is what to show while they are missing — a stretched still or a cropped
  one — and both are honest about the same absence; they differ over which lie they refuse to tell.

**The residual cost is content, never motion.** A snapshot layer's _content_ is frozen for a transition's
length; its movement is always smooth. Keep transitions short.

**The reconstruction is drawn at three scales, and there is one of it.** The cover is the desktop at full size;
the guide is the same projection small enough to answer *where am I*; the settings window's mock desktop is it
smaller again, on a scrim over the real one — with the guide drawn on it by the very object the daemon hosts,
one scalar smaller again. Each is the strip's own geometry through one scalar, so an
off-screen column, an animated resize and a gap the user is dragging appear in all three without any of them
being implemented twice — and a preview that reimplemented gap arithmetic would be a second opinion about where
a window goes. What the third one does **not** get is the reducer: a preview has no truth plane, nothing to
place, nothing to cover and nothing that can refuse, so reaching for the Engine there would not be reuse but a
second desktop.

**The strip _is_ off-screen stashing.** Windows live at absolute positions on an infinite axis; a
viewport-worth is on screen and everything else is parked off it, and workspaces are further-off regions of
that same space. This is how emira **never touches native macOS Spaces**, whose animations we could not
control. Scroll is one number with every frame derived from it, which is also the handle a continuous trackpad
gesture takes: a finger-driven scroll is not a new kind of motion but this machinery with the spring replaced
by a hand — cover up, layers sliding every frame, reals teleported once. A window cannot be moved at 120 Hz,
so the reconstruction is not merely what makes direct manipulation tractable; it is the only plane it can
happen on.

---

## 4. What emira owes the user

- **Placement lands, whatever else fails.** Every degradation ends in the same geometry: no Screen Recording
  grant collapses the whole cover ladder to `off` and disables window animation, a cover that outstays
  its welcome is dismissed on a bounded timeout, and a write an app refuses is recorded as _unknown_ rather
  than assumed. Animation is a layer over correct placement and is never a precondition for it.
- **You are never focused on something you cannot see.** Cmd-Tab, a Dock click or an app raising itself can
  land focus on a parked window, and the strip reveals it under the same motion a `focus` command gets — not
  because the motion is owed, but because a strip that jumps for one kind and glides for the other reads as
  two window managers. Two qualifications keep it honest: an app backfilling focus after a window closes is
  macOS guessing, not the user asking, and emira has already decided where focus goes; and _how much_ of
  macOS's own focus you still want is a dial, with focus onto windows emira doesn't place always admitted, or
  a modal save sheet stops working.
- **Where am I.** The strip is infinite and the screen is not, so the design owes an answer. A guide is it, and
  there are two of them because the question has two honest answers. The **minimap** is the strip's own extent
  drawn small, with a marker travelling to whichever end you are at rather than a fixed frame that can only
  ever show you the middle of itself; it is the cover's own projection at another scale, so an off-screen
  column, a workspace switch and an animated resize all appear in it without any of them being implemented
  twice. The **names** guide answers the same question with words instead of geometry — one per column, the
  focused one filled — for a strip you navigate by what is on it rather than by where it is. Neither may
  outgrow the screen it is answering about, and each concedes in its own vocabulary: the minimap takes a
  smaller scale, and the row of names crowds its words, then gives up the columns furthest from you once
  crowding them further would stop them being words. Each is a complete thing with a table of its own, and
  both are **off by default**, because a window manager must not put a HUD on somebody's screen they did
  not ask for.
- **The strip follows your hand, and where it stops is yours to choose.** A scrollable tiler's signature
  interaction is the strip tracking your fingers rather than a swipe firing a keystroke, so a three-finger
  scroll is direct manipulation: the offset is the reducer's own quantity and the hand writes it, frame by
  frame. What a lift then means is a setting, because both answers are legitimate — settle on a column edge,
  or coast to a stop wherever the momentum runs out — and only a scroll that can rest _anywhere_ proves the
  fingers were driving position at all. Which way a swipe carries the strip is a setting for a plainer
  reason: emira reads raw contacts rather than scroll events, so the system's own answer never reaches it and
  guessing would be worse than asking. **Off by default**, for the reason there are no default keybindings:
  the gesture belongs to macOS until the user hands it over.
- **What emira takes, it must be able to hand back.** A registered chord is confiscated from every application
  on the machine, so **there are no default keybindings** — a default would be emira taking a keystroke nobody
  offered it. That is also why `exec` is in the vocabulary: launching a terminal is the keystroke a window
  manager most owes its user.
- **Quitting hands the desktop back.** Parking is survivable only _while emira is running_; the moment it
  isn't, nothing else on the machine knows that a nub in the corner is a window. So the exit is a placement
  like any other — every managed window, on every workspace, stacked into one readable cascade, the window
  that had focus placed last and frontmost. A hung app delays a quit; it never prevents one.
- **A rule seeds a window; it never leashes one.** Window rules match an arriving window and give it a
  workspace, a float and a width — then are **never consulted again**. Every action seeds something a verb
  already owns, so the first press of anything hands the window straight back, and a rule holds no state of
  its own to go stale. A standing rule would be a second authority over a fact §1 says the strip already
  holds. Boot is where the asymmetry shows: emira sorting a desktop nobody just asked it to sort places
  quietly and assumes as little as it can — a matcher that reads a window against the one it opened out of
  has nothing a user chose to compare against, so it matches nothing — while a window opened _now_ is one
  you opened, and going there is already what a Dock click does.
- **A window's own resize handle still works.** A tiling window manager owns where a window goes, and the
  temptation is to read a hand on the frame as a mistake to correct. It isn't: the handle is the most direct
  thing the user can say about a size, and it says exactly what `grow` says by another route — so the size a
  drag leaves behind becomes the layout's own intent rather than something snapped away on release. What
  cannot be honoured is honoured as far as it goes, on the same terms every other resize gets: a column is as
  wide as its windows will actually be. The asymmetry with a _move_ drag is deliberate and not an oversight —
  a size is a number the strip already holds, while dragging a window somewhere would have to mean _insert
  here_, and emira does not yet have an answer to where.
- **No state without an exit.** emira will not enter a condition it has no way out of — it hides the pointer
  only while it can see the motion that would unhide it, rather than on a timeout that would also fire on
  somebody who is merely reading.
- **Configuring emira is editing its file, and the settings window is a second way to do that rather than a
  second authority.** It reads the file, writes the file, and tells the daemon nothing — hot reload does the
  rest, so the preview and the desktop cannot come to hold different opinions. It splices single values and
  never rewrites: emira is configured by hand today, and the comments, the ordering and the blank lines that
  group one table from the next are the author's work. A file it cannot parse does not open it at all — the
  menu says so and the file is one click away — because splicing text whose meaning is unknown is the one
  thing a GUI must not do, and a config that will not parse is the one most worth editing by hand.
- **A surface that covers the desktop comes off it, whatever else has failed.** The settings window dims
  every display and suspends the chords, so Escape and a double click on the dim are the whole of the way
  back to the machine, and both are unconditional. The composition is alive because it is _on screen_ rather
  than because somebody is holding it, and a dismissal that finds nothing listening takes the scrims off the
  screen itself — losing the teardown rather than the desktop. Saving is not a way out: it writes the file
  and the window stays up, so a save that read as a close would leave a dim nobody owns.
- **What the file can hold, the window can reach — or the omission is written down.** Three surfaces are
  not settings the schema can tabulate; they are still on a list (`ConfigSchema.bespoke`), and a surface
  with no editor names the reason it has none. A config the GUI silently cannot see is a config the GUI is
  lying about.
- **A config file that is wrong is an error, not a silent shrug.** Missing means defaults, because emira must
  run before it is configured. An unknown key is an error naming its line, because a window manager that
  quietly ignores `colum-gap` is one the user believes is broken. Broken on reload changes _nothing_ —
  rearranging a whole desktop as the side effect of a typo is the worst possible moment to do it. Broken at
  boot means emira manages nothing and says so, because adopting the whole desktop under defaults nobody wrote
  is indistinguishable from emira working.

---

## 5. Constraints (truths, not bugs)

- **We cannot hide, alpha, transform or re-level a foreign window.** Those need SkyLight, which needs SIP off.
  All masking is done with covers made of our own windows. This is _the_ constraint that shapes §3.
- **macOS will not let a window go fully off-screen.** Extreme coordinates clamp to a ~40 px sliver; a
  _precise_ position leaving as little as ~1 px is honoured, and how little is per app and only observable by
  asking. So a parked window is a small nub at a screen corner, positioned as a **grab handle** — the window's
  own title bar, where a user rescuing one by hand will throw the pointer. The compensation is large: **a
  window that cannot hide cannot be throttled for being hidden**, so parked windows stay warm and revealing
  one does not flash.
- **Only the owning app can produce resized pixels, and AX latency is its main thread's, not ours.** A busy
  Chrome or JVM window services us when it gets around to it. We can mask that; we cannot fix it.
- **The pointer composites above everything, including our cover**, and the public API will not let a
  background app hide it. The one route that works is §2's exception, and **passing over the Dock brings the
  cursor back whatever we do** — the window server enforces that deliberately, so it is a limit to document
  rather than a bug to work around.
- **Which app is active is macOS's to grant, per caller.** `NSRunningApplication.activate()` can simply be
  refused — a background agent is not always eligible to change activation — and its return value is the only
  sign. The Accessibility API is not subject to that decision, so the front stays reachable by writing
  `AXFrontmost` where AppKit is refused. Focus lands by whichever route is open, which is §4's bargain again:
  the placement is owed, the mechanism is not.
- **A screenshot costs per call, not per pixel, and the window server serializes them.** A covered
  transition's head cost is therefore linear in how many columns it scopes and independent of display size —
  so anything that narrows the scope is worth more than anything that makes one capture cheaper.
- **Reconstruction fidelity is make-or-break.** The layered cover must be pixel-identical to the desktop it
  replaces — backing scale, colour space, synthesized shadows — or the raise and the cross-fade pop.
- **AX describes a window's presentation, not its identity or its kind.** A subrole is not a stable fact about
  a window, and `kAXWindowsAttribute` is not a list of windows. Nothing may treat what an app says about its
  own windows as a taxonomy.
- **Both system grants can change under a running daemon.** macOS re-prompts for screen capture mid-session,
  so the grant is a live value rather than one read at boot. And a **missing Accessibility grant makes AX
  return nothing, without an error** — indistinguishable from a desktop with no windows on it — so it is
  checked first and fatally: a window manager that silently manages nothing is the worst failure available.
- **Nothing here is CPU-bound.** The hot path is AX Mach IPC (bounded by the target app's main thread) and the
  GPU compositor. Latency is masked by Core Animation, never by faster arithmetic, so smoothness work goes
  into scope and sequencing and never into micro-optimisation. Swift was chosen for interop ergonomics and
  prior-art leverage, not for speed — every framework this leans on is Apple's, and the three references doing
  our exact SIP-on task are all Swift.

---

## 6. Related implementations

- **[AeroSpace](https://github.com/nikitabobko/AeroSpace)** — our closest sibling and philosophical model:
  SIP-on, public APIs only, off-screen workspace stashing, instant placement. Its window-switch **flashing**
  is precisely the artifact §3 exists to eliminate.
- **[niri](https://github.com/YaLTeR/niri)** — where the scrollable-tiling model comes from, and our north
  star for _feel_. An inspiration, not a specification.
- **[yabai](https://github.com/koekeishiya/yabai)** — the counter-example: what smooth foreign-window control
  looks like _with_ SkyLight and SIP off. Read it to understand precisely what we give up by staying SIP-on.
