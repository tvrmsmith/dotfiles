# next-imr-item

Personal Claude Code workflow skill. Picks the next actionable **beads (bd)**
issue for the **Meridian.IMR** repo and starts work on it — drafting an agent
brief where needed, setting up an isolated workspace via a chosen orchestrator
(**superset**, **orca**, or **sbx**), and kicking off implementation. The
executing agent picks the execution skill by assessing slice size (small+clear
→ implement directly; large/ambiguous → brainstorming → writing-plans →
subagent-driven-development).

Invoke explicitly with `/next-imr-item` (model auto-invocation is disabled).

## Scope

Global skill (lives in `~/.claude/skills`, so it loads in every project) but
**gated to Meridian.IMR**. On invocation it verifies the current repo is
Meridian.IMR (origin URL / repo basename) and stops otherwise. It assumes the
`imr` CLI, a beads issue DB, the hospice product, and the personal triage
overlay in `docs/agents/triage-labels.md`.

## Invocation

- `/next-imr-item` — global scope; next most-unblocking ready item.
- `/next-imr-item <epic-id>` — restrict candidates to that epic's subtree.
- `/next-imr-item --spawn` — force a new workspace.
- `/next-imr-item --in-place` — reuse the current worktree (requires clean +
  unclaimed).
- `/next-imr-item --orchestrator <superset|orca|sbx>` (aliases `--superset`,
  `--orca`, `--sbx`) — pick the orchestrator. No default; the skill asks if the
  flag is omitted.

## Flow

0. **Resolve orchestrator** — from `--orchestrator`/alias; if absent, ask the
   user (no default). See [ORCHESTRATORS.md](ORCHESTRATORS.md).
1. **Select** — `bd ready`, filter to items carrying a `tms/ready-for-agent`
   or `tms/ready-for-human` label (drop `PRD:` containers), order by
   most-unblocking (`dependent_count` desc). See [SELECTION.md](SELECTION.md).
2. **Classify + brief** — the `tms/` label is the gate (agent vs human). On the
   agent path, if a brief already exists (issue description from `/to-issues`,
   or a brief comment) skip it; only draft one for thin/raw issues. Draft a
   human brief for `ready-for-human`.
3. **Setup** — spawn a new workspace (default) or rename in-place when clean +
   unclaimed. See [SETUP.md](SETUP.md); concrete per-orchestrator commands in
   [ORCHESTRATORS.md](ORCHESTRATORS.md).
4. **Execute or hand off** — agent items get an execution rubric and the agent
   picks the skill by slice size: small+unambiguous → implement directly;
   large/multi-component/ambiguous → brainstorming → writing-plans →
   subagent-driven-development; unsure → fuller path. Human items are handed
   off (workspace opened, no agent).
5. **Bookkeeping** — post brief, `bd update --claim`, `bd dolt commit && push`.
   In spawn mode this runs *before* the workspace is created so the spawned
   agent reads a claimed issue with its brief.

## Files

- `SKILL.md` — flow, repo gate, orchestrator gate, decision gates, bookkeeping.
- `SELECTION.md` — ready-item filter and ordering.
- `SETUP.md` — spawn vs in-place rules, naming, base branch.
- `ORCHESTRATORS.md` — orchestrator selection + per-orchestrator (superset /
  orca / sbx) create/open/in-place command mappings.

## Backup / distribution

Source of truth is this dotfiles repo. `~/.claude/skills` is stowed from
`dot-claude/skills`, so committing + pushing here is the backup — no per-repo
copy or symlink is needed anymore.
