# Issue tracker: beads (bd)

Issues for this repo live in a local Dolt DB managed by **beads**. Use the `bd` CLI for all
operations. `bd prime` prints the full command reference; this file covers only what the
Matt Pocock skills need.

Every command below has a `--json` form — prefer it when parsing.

## Conventions

- **Create an issue**: `bd create --title "..." --description "..." --type=task --priority=2`.
  Priority is `0`-`4` (0 = critical, 2 = medium), never `high`/`low`. For multi-line bodies use
  `--body-file <path>` rather than embedding newlines.
- **Read an issue**: `bd show <id> --json` — note this returns a **list**, so index `[0]`.
- **List issues**: `bd list --status open --json`. Multi-status is comma-separated
  (`--status open,in_progress`); repeating `-s` silently overwrites.
- **Comment**: `bd comment <id> "..."`, or `bd comment <id> --file <path>`.
- **Labels**: `-l/--labels` (comma-separated) on create, `bd update <id> --add-label` /
  `--remove-label` after.
- **Close**: `bd close <id> --reason "..."`. Several ids in one call is fine.
- **Delete**: `bd delete <id> --force`. There is no `deleted` status — `bd update --status deleted`
  is rejected.

Never `bd edit` — it opens `$EDITOR` and blocks.

## When a skill says "publish to the issue tracker"

`bd create`.

## When a skill says "fetch the relevant ticket"

`bd show <id> --json`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is one bead; its tickets are child beads.

- **Map**: an **epic**, labelled `wayfinder:map`, holding the Notes / Decisions-so-far /
  Not-yet-specified body.

  ```bash
  bd create --type=epic --labels wayfinder:map --title "..." --body-file <path>
  ```

  The type carries the map/ticket distinction structurally; the label stays so the query is
  still exact once this repo grows epics that are not maps. List every map with
  `bd list --type=epic --label wayfinder:map --json`.

- **Child ticket**: a child bead of the map, typed `decision` and labelled
  `wayfinder:<research|prototype|grilling|task>`.

  ```bash
  bd create --parent=<map-id> --type=decision --no-inherit-labels \
    --labels wayfinder:<type> --title "..." --body-file <path>
  ```

  **`--no-inherit-labels` is mandatory.** `bd create --parent` copies the parent's labels by
  default, so without it every ticket is born carrying `wayfinder:map` and the map query starts
  returning its own children. This has been swept by hand more than once; the flag is the fix.

  Ticket type is `decision` even for a `wayfinder:task` ticket — the label carries the wayfinder
  type, `--type` carries the tracker's.

- **Blocking**: `bd dep add <blocked-ticket> <blocker-ticket>` — beads' native dependency, which
  `bd ready` and `bd blocked` both read. Wire edges in a second pass, after every ticket has an
  id. A ticket is unblocked when all its blockers are closed.

- **Frontier query** — open, unblocked, unclaimed children of the map, in one command:

  ```bash
  bd ready --parent <map-id> --unassigned --json
  ```

  First result wins. `bd blocked` shows what is waiting and on what.

- **Claim**: `bd update <id> --claim` — the session's first write, before any work.

- **Resolve**: record the answer, then close, then index it on the map:

  ```bash
  bd comment <id> --file <answer>
  bd close <id> --reason "<one-line answer>"
  bd update <map-id> --body-file <updated-map>     # append to Decisions so far
  ```

  A ticket ruled out of scope is closed the same way and gisted into the map's **Out of scope**
  section instead.

## Sync

Conservative by default: **do not** run `bd dolt push`, `git commit`, or `git push` without
explicit authority. Report the proposed commands at handoff instead.
