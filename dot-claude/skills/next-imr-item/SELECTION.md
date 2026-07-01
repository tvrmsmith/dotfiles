# Selection

Choose the next actionable item.

## Source

Run `bd ready --json`. This yields only unblocked (currently actionable)
issues. If the output has trailing text after the JSON array, parse the
leading array only.

## Filter

Keep an issue only if BOTH hold:

- It carries a `tms/` state label of either `tms/ready-for-agent` or
  `tms/ready-for-human` (resolve strings via `docs/agents/triage-labels.md`).
- It is real work, not a container. Drop PRD/epic containers — any issue whose
  title begins with `PRD:`. These are tracking artifacts, not implementable
  items.

Drop everything else.

## Order

`bd ready` has already removed everything blocked, so all candidates are
actionable now. Order the survivors to do the most-unblocking work first:

1. `dependent_count` descending — the issue that unblocks the most other work
   (a foundational root) goes first. Read it from `bd show <id> --json`.
2. Tie-break: `dependency_count` ascending (fewer of its own prerequisites).
3. Final tie-break: issue id ascending.

## Scope

- `/start-next-item` — global: consider all filtered candidates.
- `/start-next-item <epic-id>` — restrict candidates to that epic's subtree
  (`bd dep tree <epic-id>`), then apply the same filter and order.

## Output

- Pick the top item. Print: `<id> — <title> [<state>]` and a one-line reason
  (e.g. "unblocks N items — foundational root").
- If no item passes the filter, report "no ready items" and stop.
