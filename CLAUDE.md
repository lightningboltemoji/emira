# emira — agent entry point

Read these two documents before doing anything else; they are the project:

1. **`.knowledge/PRINCIPLES.md`** — the _why_: the SIP-on charter, the two-plane model, the graphics thesis.
   Wins on principle whenever documents disagree.
2. **`.knowledge/IMPLEMENTATION.md`** — the _how_: module layout, the pure core, shell subsystems, testing
   strategy, roadmap.

House rules:

- **SIP stays on; public APIs only.** Never propose SkyLight, code injection, scripting additions, or private SPI.
- **Platform floor: macOS 26 "Tahoe".** No availability checks, no legacy paths.
- **The two documents above are ground truth, in the present tense.** They describe emira as it is now — never
  what it used to be, never when something was decided. Supersede text rather than annotating it.
- **Every change gets a change file.** `.knowledge/changes/<epoch-second>.md`, three short sections (goal,
  implementation, observations), and the same id as a `Change:` trailer on the commit. See `.knowledge/README.md`.
- **The name is `emira`, lowercase.** In prose, comments, the app bundle, and anything the app displays.
  Capitalised only where it is an identifier: the `Emira*` modules and the SwiftPM package name.
- Keep this file thin.
