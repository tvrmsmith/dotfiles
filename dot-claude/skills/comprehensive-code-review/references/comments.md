# Comment & Doc Review

Are the comments and docstrings accurate, useful, and maintainable?

## Method

1. Read the "Comments" section of the `coding-standards:coding-standards` skill. Those are the guidelines this aspect enforces.
2. For each added or changed comment, compare it against the code it describes.
3. For each added or changed hunk with no comment, ask whether the guidelines call for one.

Done when every added or changed comment has been compared against its code, and every non-obvious hunk checked for a missing one.

Check the comments *around* changed lines, not only the comments *in* them. A comment the diff never touched can still be made wrong by it.

## Severity

- **Critical** — a comment that contradicts the code it sits on; acting on it produces a wrong change.
- **Important** — missing "why", undocumented invariant or side effect.
- **Suggestion** — redundant or noise comment to delete.

Each finding gives the current comment, or its absence, and the suggested change.
