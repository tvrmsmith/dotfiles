# next-imr-item

Personal Claude Code workflow skill. Picks the next actionable **beads (bd)**
issue for the **Meridian.IMR** repo and starts work on it — drafting an agent
brief where needed, setting up an isolated Superset workspace, and kicking off
implementation via the Subagent-Driven Development skill.

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
- `/next-imr-item --spawn` — force a new Superset workspace.
- `/next-imr-item --in-place` — reuse the current worktree (requires clean +
  unclaimed).

## Flow

1. **Select** — `bd ready`, filter to items carrying a `tms/ready-for-agent`
   or `tms/ready-for-human` label (drop `PRD:` containers), order by
   most-unblocking (`dependent_count` desc). See [SELECTION.md](SELECTION.md).
2. **Classify + brief** — read the item's `tms/` state and comments. Draft an
   agent brief from the PRD + ADRs if none exists (post it to bd); draft a
   human brief for `ready-for-human`.
3. **Setup** — spawn a new workspace (default) or rename in-place when clean +
   unclaimed. See [SETUP.md](SETUP.md).
4. **Execute or hand off** — agent items run the Subagent-Driven Development
   skill; human items are handed off (workspace opened, no agent).
5. **Bookkeeping** — post brief, `bd update --claim`, `bd dolt commit && push`.
   In spawn mode this runs *before* the workspace is created so the spawned
   agent reads a claimed issue with its brief.

## Files

- `SKILL.md` — flow, repo gate, decision gates, bookkeeping.
- `SELECTION.md` — ready-item filter and ordering.
- `SETUP.md` — spawn vs in-place rules, naming, workspace creation.

## Backup / distribution

Source of truth is this dotfiles repo. `~/.claude/skills` is stowed from
`dot-claude/skills`, so committing + pushing here is the backup — no per-repo
copy or symlink is needed anymore.
