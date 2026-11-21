---
name: map-next
description: Move a wayfinder map on to its next sessions with the map-next script. Use when a wayfinder session (chart, ticket, or handoff) finishes its work, or when asked where a map stands.
---

# map-next

A wayfinder map is worked across many sessions, one per ticket. `map-next` holds the process
between them: it reads the map from bd fresh on every run, keeps no state, and prints the actions
that move the map on. Rerunning it is always safe. You run it and act on what it prints. The
process steps live in the script, so take its actions as given.

## When your session's work is done

Your work is done when the map records it: the chart created, your ticket closed and indexed, or
the handoff's tickets published. Then run it from your worktree:

```bash
~/.claude/skills/map-next/map-next <map-id> --launch
```

It prints `{"map": ..., "actions": [...]}`. `--launch` starts the `launch` and `handoff`
sessions itself and adds a `result` to each. Act on every action, then end your turn with one
message to Trevor naming what started, what waits on him, and what needs his call.

- **`launch`**: `launched`: name the ticket and its session. `claimed elsewhere`: another run took it; nothing to do. `failed`: report the `error`; the claim was handed back.
- **`hold`**: A ticket that needs Trevor, waiting for one of the slots. It launches on a later run once a slot frees.
- **`wait`**: Running elsewhere: a ticket's session, the handoff (`handoff: true`), or a docs PR not yet merged (`docs_pr`). Name it.
- **`stale`**: Claimed, but no session is live. Report it to Trevor; to relaunch, he hands the claim back with `bd update <id> --status open --assignee ""` and reruns.
- **`flag`**: A closed ticket missing from the map's index. Add its line to Decisions so far (gist from its design and close reason, linked as `bd:<id>`), then rerun. The handoff waits on every flag.
- **`fog`**: No open tickets, but Not yet specified still holds fog. Tell Trevor the map needs a `/wayfinder <map-id>` session to graduate it.
- **`handoff`**: The way is clear: a fresh session now writes the spec from the map. Name it.
- **`build`**: Send Toolsmith a status naming the `build_epic` (the `orca-cli` skill covers messaging another agent). Toolsmith starts implement-in-waves; map-next never does.

`--parent` picks where new sessions sit in Orca. The default suits every session: ticket sessions
land as siblings under the chart session. `--max N` raises the 2 tickets that need Trevor (any
type but research) allowed to run at once.

## What the sessions write

map-next reads these from bd, so each session that owns one writes it exactly this way:

- **The chart session** adds this line to the map's Notes, so every later session reaches this
  skill: `Every session ends with the map-next skill.`
- **Every resolved ticket** is indexed in Decisions so far, or in Out of scope when ruled out,
  with a `bd:<id>` link. When an answer graduates fog, clear that patch from Not yet specified
  entirely: an empty section is what lets the handoff through.
- **A ticket that wrote docs** opens one docs PR, always for Trevor's review, never auto-merged.
  Record it on the ticket, then close the ticket once the decision settles, without waiting for
  the merge:

  ```bash
  bd update <ticket-id> --set-metadata docs_pr=<PR URL>
  ```

  The handoff waits until the forge shows every docs PR on the map merged.
- **The handoff session** runs to-spec-to-tickets from the map's written record. Once to-tickets
  has published, point the map at the spec, whose children are the build tickets, then run
  map-next, which turns it into the `build` action:

  ```bash
  bd update <map-id> --set-metadata build_epic=<spec-id>
  ```
