# `.agents/`

| File                | Contents                                                | Tense      |
| ------------------- | ------------------------------------------------------- | ---------- |
| `PRINCIPLES.md`     | the charter, the two-plane model, the graphics thesis   | present    |
| `IMPLEMENTATION.md` | module layout, the pure core, shell subsystems, roadmap | present    |
| `changes/<id>.md`   | what one change did and why                             | past       |
| `DOCS.md`           | how the rest are written; the pass that ends a change   | imperative |

## Ground truth

`PRINCIPLES.md` and `IMPLEMENTATION.md` describe emira as it is now. No dated entries, no "corrected
on", no description of prior behaviour. A superseded decision has its text replaced; the previous
reading stays in git and in the change that replaced it.

## Changes

Feature work has a change id: the Unix epoch second it was made. The id names a file,
`.agents/changes/1784863319.md`.

How a comment, a change, or an edit to the two documents is written — and the pass that ends feature
work — is `DOCS.md`.
