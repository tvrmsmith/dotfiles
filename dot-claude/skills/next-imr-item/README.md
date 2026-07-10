# next-imr-item

Personal Claude Code workflow skill. Picks the next actionable **beads (bd)**
issue for the **Meridian.IMR** repo and starts work on it — drafting an agent
brief where needed, setting up an isolated workspace via a chosen orchestrator
(**superset**, **orca**, or **sbx**), and executing or handing off.

Invoke explicitly with `/next-imr-item` (model auto-invocation is disabled).
**Flow, invocation flags, and decision gates live in [SKILL.md](SKILL.md)** —
this README is human-facing framing only; SKILL.md is the source of truth.

## Scope

Global skill (lives in `~/.claude/skills`, so it loads in every project) but
**gated to Meridian.IMR**. On invocation it verifies the current repo is
Meridian.IMR (origin URL / repo basename) and stops otherwise. It assumes the
`imr` CLI, a beads issue DB, the hospice product, and the personal triage
overlay in `docs/agents/triage-labels.md`.

## Files

- `SKILL.md` — flow, repo gate, classify/execution gates, bookkeeping.
- `SELECTION.md` — ready-item filter and ordering.
- `SETUP.md` — spawn vs in-place rules, naming, base branch.
- `ORCHESTRATORS.md` — orchestrator selection + per-orchestrator (superset /
  orca / sbx) create/open/in-place command mappings.

## Backup / distribution

Source of truth is this dotfiles repo. `~/.claude/skills` is stowed from
`dot-claude/skills`, so committing + pushing here is the backup — no per-repo
copy or symlink is needed anymore.
