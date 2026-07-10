# Orchestrators

The skill is orchestrator-agnostic. SKILL.md and SETUP.md describe operations
("spawn the workspace", "foreground it"); this file gives the concrete command
per orchestrator.

## Choosing the orchestrator

There is **no default**. The orchestrator comes from an explicit flag:

- `--orchestrator <superset|orca|sbx>`, or the aliases `--superset`, `--orca`,
  `--sbx`.

If no orchestrator flag is present, **STOP and ask the user which orchestrator
to use** before any selection, brief, setup, or bookkeeping. Do not assume one.

The orchestrator choice is independent of the other flags (`--spawn`,
`--in-place`, `<epic-id>`).

## Shared conventions

- Branch: `hospice/m1-<slug>` (kebab-case of the issue title). See SETUP.md.
- Workspace / sandbox name: the human-readable issue title (sbx `--name` uses
  the slug, since it restricts to `[A-Za-z0-9.+-]`).
- Base branch: `main` unless the caller states otherwise.
- `<pointer prompt>` = the pointers-only prompt from SKILL.md "Execute or hand
  off" (read the issue on bd; consult the PRD/ADRs on-demand; then per the
  execution-mode gate — skills: apply the execution rubric, raw: implement
  directly). Never inline the brief/PRD text.

## superset (git-worktree workspaces)

- **Spawn (agent):**

      superset workspaces create --local --project <id> \
        --name "<title>" --branch hospice/m1-<slug> --base-branch main \
        --agent claude --prompt "<pointer prompt>"

  `create` returns the new workspace `id`. The `--agent` runs in a background
  terminal, so foreground it:

      superset workspaces open <id>

- **In-place (agent):** after `git branch -m <old> hospice/m1-<slug>`:

      superset workspaces update --name "<title>" --task-id <id>

- **ready-for-human:** run `create` **without** `--agent`/`--prompt`, then
  `superset workspaces open <id>`.

## orca (git-worktree worktrees)

- **Spawn (agent):**

      orca worktree create --repo path:<repo-path> \
        --name "<title>" --base-branch main <lineage> \
        --agent claude --prompt "<pointer prompt>" --activate --json

  `--activate` reveals (foregrounds) the new worktree; no separate open step.
  `create --json` returns the worktree id. `<lineage>` is resolved by the
  **Lineage** rule below — do not omit it.

### Lineage (`<lineage>`)

By default `orca worktree create` infers a parent from the caller context (the
Orca worktree/dir it runs in) and nests the new worktree **under** it. That is
usually wrong here — spawned slices should be siblings, not children of whoever
happened to invoke the skill. Resolve `<lineage>` before the create:

1. **Invoked from the primary/main worktree** → `--no-parent`. No ask. There is
   no meaningful parent to nest under. Detect the main worktree with:

       [ "$(git rev-parse --git-dir)" = "$(git rev-parse --git-common-dir)" ]

   (true ⇒ main worktree; linked worktrees — including Orca's under
   `.orca/worktrees/…` — differ.)

2. **Invoked from a non-primary worktree** → ask the user child vs sibling:
   - **child** ⇒ `--parent-worktree active`
   - **sibling** ⇒ `--no-parent`
   - Default: **sibling** when the skill was invoked with a parent epic-id
     (`/next-imr-item <epic-id>`); **no default** otherwise (user must choose).

`--no-parent` affects Orca lineage only, never git — always keep
`--base-branch main`.

- **In-place (agent):** after `git branch -m <old> hospice/m1-<slug>`, update
  Orca metadata on the current worktree:

      orca worktree set --worktree active --name "<title>"

  To start the agent in the current worktree (no new checkout):

      orca terminal create --worktree active --command "claude" --prompt "<pointer prompt>"

- **ready-for-human:** run `worktree create` **without** `--agent`/`--prompt`,
  keep `--activate` and the resolved `<lineage>` flag.

## sbx (Docker container sandboxes)

sbx has no host git-worktree/branch concept. Isolation comes from the
container. `sbx run` attaches interactively (already foreground) — no open step.

- **Spawn (agent)** ⇒ `--clone`: agent works on a private in-container clone;
  it creates the branch inside the container, and commits are reachable on the
  host via the `sandbox-<name>` git remote. No host `--branch`/`--base-branch`.

      sbx run --clone --name hospice-m1-<slug> claude . -- "<pointer prompt>"

- **In-place (agent)** ⇒ no `--clone`: bind-mount the current worktree. Rename
  the branch on the host first (`git branch -m <old> hospice/m1-<slug>`), then:

      sbx run --name hospice-m1-<slug> claude . -- "<pointer prompt>"

- **ready-for-human:** `sbx run` opens an interactive claude session, so the
  human drives it — launch **without** the `-- "<pointer prompt>"` autonomous
  seed. Use `--clone` for spawn, omit it for in-place:

      sbx run [--clone] --name hospice-m1-<slug> claude .

### sbx bookkeeping caveat

The `--clone` container clones the host repo (including the dolt beads DB), so
the claim + brief must be committed and `dolt push`ed **before** `sbx run
--clone` — otherwise the container clones a pre-claim state. This is the same
"bookkeeping before spawn" rule as the others (SKILL.md → Bookkeeping); it just
matters more here because the clone is a point-in-time copy.
