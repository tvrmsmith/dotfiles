# Recovering a lost fan-out batch

Someone cannot find the session that fanned a batch out, or cannot find a worker. Fan-out wrote
nothing at spawn, so recovery is a query — and the thing queried is **the beads**. Beads outlive
their workers: a worktree removed before `/orca-fan-in` is gone from every Orca listing, and that
is exactly the case recovery exists for. Orca state is the enrichment layer over the beads, never
the index.

**This session reports and navigates.** The batch stays owned by the original handle, which
in-flight workers still push to — that handle also stays the one that spawns any next sequential
row. Everything below is read-only until the human asks to jump or to re-anchor a commit.

## 1. Build the roster from the beads

Batch rows are beads the workers claimed and closed. Take the window the human names, or the last
24 hours:

```text
bd list --status=in_progress --json
bd list --status=closed --closed-after=<YYYY-MM-DD> --json
```

Each row is one bead: `id`, `title`, `status`, `assignee`, and — for a closed one — `close_reason`
(`bd show <id> --json` carries the same fields for a single bead). **The close reason is the
result line.** A worker that closed its bead reported its outcome there whether or not the push
ever landed, so a closed bead with a reason needs no worker to be read.

Ask the human which of these rows are their batch when the window catches unrelated beads. If the
repo has no beads DB, skip to the appendix.

## 2. Enrich from Orca

Only now bring in Orca, to say where each row's worker stands:

```text
ORCA worktree list --json
```

**Handles are aliases.** The same tab can be named by different handle strings (observed live:
one tab reported as `term_be078a14…` by `list` and `term_07cece81…` by `show`), so two aliases for
one tab would split a single batch into two groups. Resolve every
`cliProvenance.callerTerminalHandle` through `ORCA terminal show --terminal <handle> --json` and
use `result.terminal.handle` before comparing handles, grouping on them, or switching. A handle
that no longer resolves keeps its raw string.

Match `result.worktrees[]` rows to bead rows by `displayName` (the slug) and `branch`, then per
bead row print:

| bead | status | worker | branch | workspaceStatus | linkedPR | isArchived |

- **Worktree present** — those columns come straight from the listing, exact.
- **Worktree absent** — print `worker gone` and go to step 3. This is the interesting row.

The canonicalized `cliProvenance.callerTerminalHandle` shared by the surviving worktrees names the
orchestrator. Print it, and whether `terminal show` still resolves it. If every worktree in the
batch is gone the orchestrator has no witness left in Orca; ask the human which tab it was, or
leave it unnamed and report the bead rows alone.

**Tab rows leave no trace the CLI can read.** Terminals expose no provenance and no environment
from outside, and the `title` the CLI reports is the pane's activity title, not the tab label
fan-out set — so a tab worker's bead is all the CLI has. With a live orchestrator handle, list
its worktree's terminals as unattributed candidates:

```text
ORCA terminal show --terminal <orchestrator-handle> --json      # → result.terminal.worktreeId
ORCA terminal list --worktree id:<worktreeId> --json
```

Print `handle`, `title`, `preview`, and `lastOutputAt` per terminal, under a heading that says
plainly these are candidates rather than confirmed members — the orchestrator's own tab and
unrelated tabs land in this list too. That `title` is activity text, so it will not match a
slug; use `preview` and `lastOutputAt` to narrow, then **have the human match the row against
the tab labels in the sidebar**, which do carry the slugs. The human closes this gap, not the
CLI.

## 3. Rescue a gone worker's commit

Removing a worktree deletes its branch, leaving the commit dangling. Read the bead's
`close_reason` for the sha the brief required, then offer — do not run — the re-anchor:

```text
git branch <slug> <sha>
```

If the reason names no sha, the commit is reachable only until git garbage-collects it. Say that
plainly, and offer `git fsck --unreachable --no-reflogs` in the repo to enumerate what is left,
with the bead's close time as the clue for which commit is the worker's. Report what you find and
stop; the human decides what to re-anchor.

A bead still `in_progress` with no worktree is a worker that died without reporting. Its work, if
any, is in the same dangling state — and the bead is the only place it was ever named.

## 4. Offer to jump

**Live orchestrator handle.** Name the command and wait for the human to ask for it:

```text
ORCA terminal switch --terminal <handle> --json
```

Then stop. Once the human is back in the orchestrator session, that session owns the batch again
and `/orca-fan-in` in a worker pushes there as before.

**Dead orchestrator handle.** There is nothing to switch to. Print the roster, say that in-flight
pushes will land nowhere and that those workers should hand their result line to the human instead
— `/orca-fan-in` already stops and prints the line when the handle is gone — then stop. This
session reports and navigates: it names where each worker stands and leaves it there.

## Appendix: no beads DB

With no beads there is no index, only Orca's own state, and a removed worktree is unrecoverable
through it. Take `result.worktrees[]` from `ORCA worktree list --json`, keep the rows carrying a
`cliProvenance`, canonicalize and group by `callerTerminalHandle` as above, and keep the groups
whose newest `createdAt` (epoch ms) falls in the window, newest first. Per group print the
canonical caller handle, whether it still resolves, the member slugs, and the newest `createdAt`.
Show dead-handle groups too — a dead orchestrator is exactly when someone is most lost. Groups may
include non-fan-out creates, since `cliProvenance` is stamped by any CLI create; the slugs
disambiguate. Ask the human which group is theirs, then continue at step 2's roster table.
