// The graphical settings window: a scrim over every display, the user's own desktop drawn small and
// floating above it, and the controls floating beside that. See `PLAN.md` while this is being built.
//
// **The boundary, and it is the reason this is a target rather than a folder.** This module may read
// `Config` and call `Layout`, `Strip` and `LayoutMetrics`. It may not name `Engine`, `State`, `Event`,
// `Effect` or `Command`.
//
// The line falls there because what a preview honestly needs is the *geometry*, and geometry is the
// authority worth sharing — a mock desktop that reimplemented gap arithmetic would be a second opinion
// about where a window goes. What the reducer does is reconcile a truth plane against a structure, and
// a preview has no truth plane: nothing to place, nothing to cover, nothing that can refuse.
//
// `EmiraConfig` depends on `EmiraCore`, so the module graph does not enforce this on its own — the
// reducer stays one `import` away. `ImportFenceTests` is what pins it.
