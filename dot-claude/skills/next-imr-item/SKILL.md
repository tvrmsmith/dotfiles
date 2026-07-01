---
name: next-imr-item
description: Pick the next ready beads item by dependency order and start work on it — sets up a Superset workspace and kicks off implementation. Handles ready-for-agent (with or without brief) and ready-for-human states. Meridian.IMR only.
disable-model-invocation: true
---

# Next IMR Item

Pick the next actionable beads item and start work. Resolve `tms/` label strings via `docs/agents/triage-labels.md`.

## Repo gate — Meridian.IMR only

Global skill, but only applies to the **Meridian.IMR** repo (assumes `imr`, beads, hospice, `docs/agents/triage-labels.md`). Before anything else, confirm the current repo is Meridian.IMR:

- `git config --get remote.origin.url` contains `Meridian.IMR`, OR the repo toplevel / git-common-dir basename is `Meridian.IMR`.

If not Meridian.IMR, STOP and report: "next-imr-item only runs in the Meridian.IMR repo." Do not proceed.

## Invocation

- `/next-imr-item` — global scope, next most-unblocking item.
- `/next-imr-item <epic-id>` — restrict to that epic's subtree.
- `/next-imr-item --spawn` — force a new workspace.
- `/next-imr-item --in-place` — reuse current worktree (requires clean + unclaimed).

## Flow

1. Select the next item — see [SELECTION.md](SELECTION.md).
2. Classify + brief (below).
3. Decide spawn vs in-place + set up the workspace — see [SETUP.md](SETUP.md).
4. Execute or hand off (below).
5. Record bookkeeping (below).

## Classify + brief

The **`tms/` label is the gate** — it decides agent vs human, not any content inspection. Read it (resolve via `docs/agents/triage-labels.md`):

- **`tms/ready-for-agent`** → agent path. A brief is the mattpocock triage artifact for *raw* issues; a slice split from a PRD by `/to-issues` already carries brief-equivalent detail in its description (What to build + acceptance criteria + refs), so don't duplicate it.
  - **Brief already present** — in the issue description OR a brief comment → skip drafting, proceed to setup.
  - **No brief** (thin / hand-filed issue) → draft one from the PRD + linked ADRs following the mattpocock AGENT-BRIEF guide. Show for approval. If an unresolved decision remains, auto-escalate: grill it into shape, or reclassify to `tms/ready-for-human`. Post it with `bd comment <id>`.
- **`tms/ready-for-human`** → draft a human-brief (same structure; note why it can't be delegated: judgment calls, external access, design decisions, manual testing). No autonomous execution.

## Execute or hand off

Agent items run the **full brainstorming flow**, not Subagent-Driven Development (SDD) directly. A bd brief is not an implementation plan — pointing an agent straight at SDD makes it stall and improvise blueprints. Brainstorming resolves any residual ambiguity, then chains to writing-plans (which produces the plan) and finally SDD to execute. Entry point: `superpowers:brainstorming` with the brief + PRD as input.

- **agent, in-place** → invoke `superpowers:brainstorming` with the brief + PRD as input. Let it flow through writing-plans → subagent-driven-development.
- **agent, spawn** → the `superset ... --prompt` is pointers only: "read the agent brief on bd `<id>`, read the PRD `<epic-id>`, then run the superpowers:brainstorming skill to turn it into a design — it chains to writing-plans then subagent-driven-development." Never inline the brief text. **Run bookkeeping (below) BEFORE creating the workspace** — the spawned agent reads the brief from beads, so the comment + claim must be `dolt push`ed first, or it races an empty/unclaimed issue. After create, foreground it with `superset workspaces open <id>` (the agent otherwise runs in a background terminal).
- **ready-for-human** (either mode) → set up the workspace/branch, post the human-brief, `superset workspaces open` for the user. No `--agent`.

## Bookkeeping

Per pickup, in order. In **spawn** mode this whole section runs BEFORE the
workspace is created (see Execute or hand off); in **in-place** mode it runs
after setup.

1. If a brief was drafted, post it: `bd comment <id> "<brief>"`.
2. Claim: `bd update <id> --claim` (atomically sets assignee = you and status = `in_progress`).
3. Sync: `bd dolt commit` then `bd dolt push` (so a spawned workspace sees the brief and the item leaves future `bd ready` scans).

## Error handling

- No ready items → report, stop.
- `--in-place` requested but worktree dirty/claimed → stop, tell the user.
- Any `bd` or `superset` command fails → surface the exact error and stop. Never leave a claim unsynced.
- Reclassify to human mid-run → stop the autonomous path, hand off.
