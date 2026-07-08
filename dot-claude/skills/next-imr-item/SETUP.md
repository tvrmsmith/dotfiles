# Setup

Decide where work happens, then create/prepare the workspace. The concrete
create/open commands per orchestrator live in
[ORCHESTRATORS.md](ORCHESTRATORS.md); this file covers the spawn-vs-in-place
decision, naming, and base branch that apply across all of them.

## Spawn vs in-place

Default is **spawn**. Use **in-place** only when BOTH hold:

1. Invoked from inside an existing workspace worktree (not the repo main
   directory).
2. That worktree is clean (`git status --porcelain` empty) AND unclaimed (not
   bound to an `in_progress` bd item).

sbx has no persistent host worktree of its own: spawn ⇒ `--clone` (isolated
container), in-place ⇒ no `--clone` (bind-mounts the current worktree). The
clean+unclaimed rule below still gates in-place.

| Where / state | Action |
| --- | --- |
| Repo main directory | Spawn new workspace |
| Workspace worktree, clean + unclaimed | In-place rename |
| Workspace worktree, dirty or claimed | Spawn (avoid clobber) |

Flags: `--spawn` forces spawn anywhere. `--in-place` requires worktree + clean
+ unclaimed; else STOP and tell the user (dirty/claimed) to commit/stash or
pass `--spawn`.

## Naming

Derive from the issue title (`bd show <id>`):
- Branch: `hospice/m1-<slug>` (kebab-case of the title, trimmed).
- Workspace name: the human-readable title.

## Base branch

Fork from `main` unless the caller states otherwise. (For sbx `--clone` there
is no host base-branch flag — the agent branches inside the container.)

## In-place

- `git branch -m <old> hospice/m1-<slug>`
- Update the orchestrator's metadata for the current worktree and start the
  agent — see [ORCHESTRATORS.md](ORCHESTRATORS.md) (superset `workspaces
  update`, orca `worktree set` + `terminal create`, sbx `run` without `--clone`).

## Spawn

Create a fresh isolated workspace on `hospice/m1-<slug>` from `main` with agent
`claude` and the pointer prompt, then foreground it. Concrete command per
orchestrator (and the ready-for-human variant with no agent) is in
[ORCHESTRATORS.md](ORCHESTRATORS.md).

For orca, also resolve worktree **lineage** (parent vs sibling vs top-level)
before the create — see the Lineage rule in
[ORCHESTRATORS.md](ORCHESTRATORS.md). Default: `--no-parent` from the main
worktree; otherwise ask (sibling default only when an epic-id was passed).

Run bookkeeping (SKILL.md → Bookkeeping) **before** the create so a spawned
agent — and especially an sbx `--clone` snapshot — reads a claimed, briefed
issue.
