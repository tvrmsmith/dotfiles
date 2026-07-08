---
name: next-imr-item
description: Pick the next ready beads item by dependency order and start work on it — sets up an isolated workspace via a chosen orchestrator (superset, orca, or sbx) and kicks off implementation. Handles ready-for-agent (with or without brief) and ready-for-human states. Meridian.IMR only.
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
- `/next-imr-item --orchestrator <superset|orca|sbx>` (aliases `--superset`,
  `--orca`, `--sbx`) — pick the orchestrator. **No default** — if omitted, STOP
  and ask which one before doing anything. See [ORCHESTRATORS.md](ORCHESTRATORS.md).

## Orchestrator gate

The orchestrator has no default. Resolve it from the flag/alias before
selection. If none was given, ask the user and wait — do not select, brief, set
up, or run bookkeeping until it is known. See [ORCHESTRATORS.md](ORCHESTRATORS.md).

## Flow

1. Resolve the orchestrator (above) — ask if not supplied.
2. Select the next item — see [SELECTION.md](SELECTION.md).
3. Classify + brief (below).
4. Decide spawn vs in-place + set up the workspace — see [SETUP.md](SETUP.md)
   and [ORCHESTRATORS.md](ORCHESTRATORS.md) for the concrete commands.
5. Execute or hand off (below).
6. Record bookkeeping (below).

## Classify + brief

The **`tms/` label is the gate** — it decides agent vs human, not any content inspection. Read it (resolve via `docs/agents/triage-labels.md`):

- **`tms/ready-for-agent`** → agent path. A brief is the mattpocock triage artifact for *raw* issues; a slice split from a PRD by `/to-issues` already carries brief-equivalent detail in its description (What to build + acceptance criteria + refs), so don't duplicate it.
  - **Brief already present** — in the issue description OR a brief comment → skip drafting, proceed to setup.
  - **No brief** (thin / hand-filed issue) → draft one from the PRD + linked ADRs following the mattpocock AGENT-BRIEF guide. Show for approval. If an unresolved decision remains, auto-escalate: grill it into shape, or reclassify to `tms/ready-for-human`. Post it with `bd comment <id>`.
- **`tms/ready-for-human`** → draft a human-brief (same structure; note why it can't be delegated: judgment calls, external access, design decisions, manual testing). No autonomous execution.

## Execute or hand off

The executing agent picks the execution skill by **assessing the slice** — don't hardcode one. Hardcoding mismatches half the slices (SDD alone is too light and makes the agent improvise plans; full brainstorming is too heavy for a trivial fix). The agent holds the most context (description + PRD + ADRs + prior art), so it judges. The **execution rubric** (hand this to the agent verbatim):

> Assess the slice, then pick:
> - Small + unambiguous (1–2 components, clear acceptance) → implement directly (`/implement` or straight TDD).
> - Large / multi-component / any unresolved design question → `superpowers:brainstorming` → writing-plans → subagent-driven-development.
> - Unsure → take the fuller path.

- **agent, in-place** → hand the agent the execution rubric with the issue (`bd show <id>`) + PRD as input.
- **agent, spawn** → the orchestrator's `--prompt` (or sbx `-- "…"`) is pointers only: "read the issue on bd `<id>` (and its brief comment if any), read the PRD `<epic-id>` and linked ADRs, then apply the execution rubric: small+clear → implement directly; large/ambiguous → brainstorming → writing-plans → subagent-driven-development; unsure → fuller path." Never inline the brief text. **Run bookkeeping (below) BEFORE creating the workspace** — the spawned agent reads the issue from beads, so the comment + claim must be `dolt push`ed first, or it races an empty/unclaimed issue (doubly so for sbx `--clone`, which snapshots the repo). After create, foreground it per the orchestrator (superset/orca need an explicit open/activate; sbx `run` already attaches). See [ORCHESTRATORS.md](ORCHESTRATORS.md).
- **ready-for-human** (either mode) → set up the workspace/branch, post the human-brief, and open it for the user with no autonomous agent (superset/orca: create without `--agent`; sbx: `sbx run claude` without the prompt seed — an interactive session the human drives). See [ORCHESTRATORS.md](ORCHESTRATORS.md).

## Bookkeeping

Per pickup, in order. In **spawn** mode this whole section runs BEFORE the
workspace is created (see Execute or hand off); in **in-place** mode it runs
after setup.

1. If a brief was drafted, post it: `bd comment <id> "<brief>"`.
2. Claim: `bd update <id> --claim` (atomically sets assignee = you and status = `in_progress`).
3. Sync: `bd dolt commit` then `bd dolt push` (so a spawned workspace — including an sbx `--clone` snapshot — sees the brief and the item leaves future `bd ready` scans).

## Error handling

- No ready items → report, stop.
- `--in-place` requested but worktree dirty/claimed → stop, tell the user.
- No orchestrator flag/alias given → ask the user; do not assume a default.
- Any `bd` or orchestrator (`superset`/`orca`/`sbx`) command fails → surface the exact error and stop. Never leave a claim unsynced.
- Reclassify to human mid-run → stop the autonomous path, hand off.
