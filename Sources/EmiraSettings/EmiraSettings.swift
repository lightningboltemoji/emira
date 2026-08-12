// The graphical settings window: a scrim over every display, the user's own desktop drawn small and
// floating above it, and the controls floating beside that.
//
// **The boundary, and it is the reason this is a target rather than a folder.** This module may read
// `Config` and call `Layout`, `Strip` and `LayoutMetrics`. It may not name `Engine`, `State`, `Event`,
// `Effect` or `Command`.
//
// **`Vocabulary` and `Verb` are not a sixth.** The five forbidden names are the reducer: its state, its
// input, its output, and the machine between them. The vocabulary is the *spellings* — the words a
// binding is written in — and a keybinding editor has to offer them, which is a different thing from
// consuming them. What crosses is `String`: a verb's name, its summary, the shape of its argument. The
// panel composes `focus left` and hands it to the draft, the draft hands it to the schema, and the
// schema is where it becomes a `Command` — in another module, as it always was. `Cue` established the
// pattern before there was an editor to need it.
//
// The line falls there because what a preview honestly needs is the *geometry*, and geometry is the
// authority worth sharing — a mock desktop that reimplemented gap arithmetic would be a second opinion
// about where a window goes. What the reducer does is reconcile a truth plane against a structure, and
// a preview has no truth plane: nothing to place, nothing to cover, nothing that can refuse.
//
// `EmiraConfig` depends on `EmiraCore`, so the module graph does not enforce this on its own — the
// reducer stays one `import` away. `ImportFenceTests` is what pins it.
