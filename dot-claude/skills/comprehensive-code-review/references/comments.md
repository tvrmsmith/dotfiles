# Comment & Doc Review

Verify comments and docstrings accurate, useful, maintainable. **Advisory only** — report findings; the caller applies changes.

## Method

Each added/changed comment, compare against code it describes.

## What to check

- **Factual accuracy** — comment match what code does? Wrong comment worse than none.
- **Comment rot** — stale comments describing old behavior, TODOs long done, references to renamed/removed symbols.
- **Completeness** — non-obvious logic, invariants, units, side effects, "why" undocumented. Public APIs missing docs.
- **Redundancy** — comments restating obvious code (`i++ // increment i`). Add noise, rot risk.
- **Intent vs mechanics** — good comments explain *why*, not *what*. Flag comments narrating code instead of reason.

## Severity

- **Critical** — inaccurate/misleading comments that mislead readers.
- **Important** — missing "why", undocumented invariants/side effects.
- **Suggestion** — redundant/noise comments to delete.

Each finding gives the current comment (or its absence) and the suggested change. Note comments adding real value too.