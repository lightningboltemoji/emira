# `.knowledge/`

| File | Contents | Tense |
| --- | --- | --- |
| `PRINCIPLES.md` | the charter, the two-plane model, the graphics thesis | present |
| `IMPLEMENTATION.md` | module layout, the pure core, shell subsystems, roadmap | present |
| `changes/<id>.md` | what one change did and why | past |

## Ground truth

`PRINCIPLES.md` and `IMPLEMENTATION.md` describe emira as it is now. No dated entries, no "corrected
on", no description of prior behaviour. A superseded decision has its text replaced; the previous
reading stays in git and in the change that replaced it. A date in either file marks a sentence that
belongs in a change.

## Changes

Each commit has a change id: the Unix epoch second it was made. The id names a file,
`.knowledge/changes/1784863319.md`, and repeats as a commit trailer:

```
add outer-gap

Change: 1785089081
```

Epoch seconds sort chronologically and do not collide. Nothing parses them.

## Where an explanation goes

A comment says what a reader needs to understand the code in front of them. Everything else — the
investigation, the rejected alternatives, the bug that motivated a line, the numbers that proved it —
belongs in the change, and `git blame` reaches it. A comment carrying that weight is unparseable at
the moment someone actually needs it: it is read while chasing something else.

- **Three lines is the working ceiling** for a declaration, and most need one. If it wants more, the
  surplus is history and the change file is where it goes.
- **Say the constraint, not the derivation.** "A tile this far off-screen is clamped back into view by
  macOS" is the fact; how it was found is not.
- **Never date, attribute, or narrate.** No "previously", no "we changed this because", no bug ids.
  `PRINCIPLES.md` and `IMPLEMENTATION.md` are present-tense for the same reason.
- The two documents are the exception that proves it: prose *is* their code, and an argument that
  belongs to the design as a whole lives there rather than above the line that happens to implement it.

Change file format — three sections, normally under three paragraphs:

```markdown
# <title>

> Change `<id>` — <date>

## Goal

The problem this addresses.

## Implementation

Pull-request altitude: what a reviewer needs to read the diff. Decisions and the reasons for them,
rejected alternatives and their failure modes. Not a restatement of the code.

## Observations

Known limits, untested areas, follow-up work.
```
