# Comment & Doc Review

Verify comments and docstrings accurate, useful, maintainable. **Advisory only — do not modify code.** Report findings; caller decides.

## Method

Each added/changed comment, compare against code it describes.

## What to check

- **Factual accuracy** — comment match what code does? Wrong comment worse than none.
- **Comment rot** — stale comments describing old behavior, TODOs long done, references to renamed/removed symbols.
- **Completeness** — non-obvious logic, invariants, units, side effects, "why" undocumented. Public APIs missing docs.
- **Redundancy** — comments restating obvious code (`i++ // increment i`). Add noise, rot risk.
- **Intent vs mechanics** — good comments explain *why*, not *what*. Flag comments narrating code instead of reason.

## Output

- **Critical issues** — inaccurate/misleading comments that mislead readers `[file:line]`.
- **Improvements** — missing "why", undocumented invariants/side effects `[file:line]`.
- **Removals** — redundant/noise comments to delete `[file:line]`.
- **Positive** — comments adding real value.

Each item: current comment (or absence) → suggested change. Do not edit code yourself.