# Setup

Decide where work happens, then create/prepare the workspace.

## Spawn vs in-place

Default is **spawn**. Use **in-place** only when BOTH hold:

1. Invoked from inside an existing Superset workspace worktree (not the repo
   main directory).
2. That worktree is clean (`git status --porcelain` empty) AND unclaimed (not
   bound to an `in_progress` bd item).

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

Fork from `main` unless the caller states otherwise.

## In-place

- `git branch -m <old> hospice/m1-<slug>`
- `superset workspaces update --name "<title>" --task-id <id>` on the current
  workspace.

## Spawn

    superset workspaces create --local --project <id> \
      --name "<title>" --branch hospice/m1-<slug> --base-branch main \
      --agent claude --prompt "<pointer prompt>"

`create` returns the new workspace `id`. A spawned `--agent` runs in a
background terminal, so always foreground it after create:

    superset workspaces open <id>

For ready-for-human, omit `--agent` and `--prompt` from `create`, then run the
same `superset workspaces open <id>` on the new workspace.
