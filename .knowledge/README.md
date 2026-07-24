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
