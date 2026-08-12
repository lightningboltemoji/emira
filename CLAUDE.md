`.agents/README.md` provides context on the project and how knowledge is managed.

House rules:

- Bias towards clean architecture. Ask yourself if this is the right solution or the easy one.
- Bias towards validating instead of guessing. Where Swift snippets won't do, running the daemon and moving windows is never an interruption.
- Before removing a mechanism, measure what it buys — a stale rationale is not a wrong decision, and the suite usually already prices it.
- Keep this file thin.
- Use a worktree. Don't make direct changes, even for prototyping.
