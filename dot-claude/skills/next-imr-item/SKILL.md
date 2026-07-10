---
name: next-imr-item
description: Pick the next ready beads item (dependency-ordered) and start work via a chosen orchestrator (superset, orca, or sbx). Meridian.IMR only.
disable-model-invocation: true
---
# Next IMR Item

Pick next actionable beads item, start work. Resolve `tms/` label strings via `docs/agents/triage-labels.md`.

## Repo gate — Meridian.IMR only

Global skill, only applies to **Meridian.IMR** repo (assumes `imr`, beads, hospice, `docs/agents/triage-labels.md`). First, confirm current repo is Meridian.IMR:

- `git config --get remote.origin.url` contains `Meridian.IMR`, OR repo toplevel / git-common-dir basename is `Meridian.IMR`.

If not Meridian.IMR, STOP and report: "next-imr-item only runs in the Meridian.IMR repo." Do not proceed.

## Invocation

- `/next-imr-item` — global scope, next most-unblocking item.
- `/next-imr-item <epic-id>` — restrict to that epic subtree.
- `/next-imr-item --spawn` — force new workspace.
- `/next-imr-item --in-place` — reuse current worktree (requires clean + unclaimed).
- `/next-imr-item --orchestrator <superset|orca|sbx>` (aliases `--superset`,
  `--orca`, `--sbx`) — pick orchestrator. **No default** — if omitted, STOP
  and ask which one before anything. See [ORCHESTRATORS.md](ORCHESTRATORS.md).

## Flow

1. Resolve orchestrator — **no default; if not supplied, ask the user and wait** (do not select, brief, set up, or run bookkeeping until known). See [ORCHESTRATORS.md](ORCHESTRATORS.md).
2. Select next item — see [SELECTION.md](SELECTION.md).
3. Classify + brief (below).
4. Decide spawn vs in-place + set up workspace — see [SETUP.md](SETUP.md)
   and [ORCHESTRATORS.md](ORCHESTRATORS.md) for concrete commands.
5. Execute or hand off (below) — ask execution-mode gate first (skills vs raw).
6. Bookkeeping (below) — **spawn: run BEFORE step 4 (workspace create); in-place: after setup**.

## Classify + brief

**`tms/` label is gate** — decides agent vs human, not content inspection. Read it (resolve via `docs/agents/triage-labels.md`):

- **`tms/ready-for-agent`** → agent path. Brief is mattpocock triage artifact for *raw* issues; slice split from PRD by `/to-tickets` already carries brief-equivalent detail in description (What to build + acceptance criteria + refs), so don't duplicate.
  - **Brief already present** — in issue description OR brief comment → skip drafting, proceed to setup.
  - **No brief** (thin / hand-filed issue) → draft one from PRD + linked ADRs following mattpocock AGENT-BRIEF guide. Show for approval. If unresolved decision remains, auto-escalate: grill into shape, or reclassify to `tms/ready-for-human`. Post with `bd comment <id>`.
- **`tms/ready-for-human`** → draft human-brief (same structure; note why can't delegate: judgment calls, external access, design decisions, manual testing). No autonomous execution.

## Execute or hand off

**Execution-mode gate (ask first).** Before handoff, ask user: use Matt Pocock skills (`/grill-with-docs`, `/implement`), or pass beads context and go raw? Wait for answer.

**What to pass — exactly this, nothing more:**

1. Beads issue pointer `bd <id>` (agent runs `bd show <id>`; note brief comment if any).
2. PRD pointer `<epic-id>`, read on-demand — never inline PRD text (often large; well-formed `/to-tickets` slices self-contained). Agent consults PRD + linked ADRs only if issue lacks needed context.
3. **Skills** mode → execution rubric verbatim (below). **Raw** mode → "implement it directly."

**Pass only pointers + slice-specific detail.** Coding standards, tests, TDD, lint/verify, and commit conventions already live in `CLAUDE.md` (auto-loaded) and the invoked skills — don't restate them.

**Rubric lives with execution agent, not orchestrator** — real complexity shows only once you touch code, so agent holding most context (issue + PRD + ADRs + prior art + codebase) picks depth. Rubric (hand verbatim in skills mode):

> Assess slice, then pick:
> - Small + unambiguous, startable now (1–2 components, clear acceptance) → `/implement`.
> - Large / multi-component / unresolved design question / ambiguous → `/grill-with-docs` (grilling + `/domain-modeling`, produces ADRs + glossary), then `/implement`.
> - Unsure → `/grill-with-docs`.

**Handoff mechanics:**

- **in-place** → hand above to agent in current worktree.
- **spawn** → pack above into orchestrator `--prompt` (sbx `-- "…"`) as pointers only; never inline brief/PRD text. **Run bookkeeping (below) BEFORE creating workspace** — spawned agent reads issue from beads, so comment + claim must be `dolt push`ed first or it races empty/unclaimed issue (esp. sbx `--clone`, a repo snapshot). After create, foreground per orchestrator (superset/orca need explicit open/activate; sbx `run` attaches).
- **ready-for-human** → set up workspace/branch, post human-brief, open with no autonomous agent (superset/orca: create without `--agent`; sbx: `sbx run claude` without prompt seed).

See [ORCHESTRATORS.md](ORCHESTRATORS.md) for concrete per-orchestrator commands.

## Bookkeeping

Per pickup, in order. In **spawn** mode whole section runs BEFORE
workspace created (see Execute or hand off); in **in-place** mode runs
after setup.

1. If brief drafted, post it: `bd comment <id> "<brief>"`.
2. Claim: `bd update <id> --claim` (atomically sets assignee = you and status = `in_progress`).
3. Sync: `bd dolt commit` then `bd dolt push` (so spawned workspace — including sbx `--clone` snapshot — sees brief and item leaves future `bd ready` scans).

## Error handling

- No ready items → report, stop.
- `--in-place` requested but worktree dirty/claimed → stop, tell user.
- No orchestrator flag/alias given → ask user; do not assume default.
- Any `bd` or orchestrator (`superset`/`orca`/`sbx`) command fails → surface exact error and stop. Never leave claim unsynced.
- Reclassify to human mid-run → stop autonomous path, hand off.