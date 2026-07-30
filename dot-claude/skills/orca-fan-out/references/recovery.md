# Recovering a lost fan-out batch

Someone cannot find the session that fanned a batch out. Rebuild the **roster** from Orca's own
state: fan-out wrote nothing at spawn, so recovery is a query, not a lookup.

**This session reports and navigates.** The batch stays owned by the original handle, which
in-flight workers still push to — that handle also stays the one that spawns any next sequential
row. Everything below is read-only until the human asks to jump.

## 1. List candidate orchestrators

Every CLI-created worktree carries `cliProvenance.callerTerminalHandle`: the terminal that ran
`worktree create`. Grouping by that handle **is** the batch.

```text
ORCA worktree list --json
```

**Handles are aliases.** The same tab can be named by different handle strings (observed live:
one tab reported as `term_be078a14…` by `list` and `term_07cece81…` by `show`), so two aliases
for one tab would split a single batch into two groups. Resolve every
`cliProvenance.callerTerminalHandle` through `ORCA terminal show --terminal <handle> --json` and
use `result.terminal.handle` before comparing handles, grouping on them, or switching. A handle
that no longer resolves keeps its raw string — it stays its own group.

Take `result.worktrees[]`, keep the rows that have a `cliProvenance`, and group them by that
canonicalized caller handle. Keep groups whose newest `createdAt` (epoch ms) falls in the last 24
hours, newest group first. Per group print:

- the canonical caller handle, and whether it is still live — the `terminal show` above
  succeeding, with `result.terminal.title` naming that tab
- member slugs (`displayName`)
- the group's newest `createdAt`

Show dead-handle groups too. A dead orchestrator is exactly when someone is most lost.

Groups may include non-fan-out creates — `cliProvenance` is stamped by any CLI create; the slugs
disambiguate.

Ask the human which group is their batch. If they recognize none, widen to all groups regardless
of age, newest first, and ask again.

## 2. Print that group's roster

**Worktree rows are exact**, straight from the same `worktree list` output:

| slug (`displayName`) | branch | status (`workspaceStatus`) | PR (`linkedPR`) | archived (`isArchived`) | path |

**A dead-handle group's roster stops there.** The tab-candidate listing below starts from
`terminal show` on the orchestrator handle, which errors for exactly the dead-handle groups step
1 keeps. For such a group the roster is the worktree rows above and nothing else: say so, skip
the listing, and go to step 3.

**Tab rows are a guess.** Terminals expose no provenance and no environment from outside, and
Orca renames tabs from agent activity, so a tab worker leaves no outside-visible marker. List
every live terminal sharing the orchestrator's worktree as an unattributed candidate:

```text
ORCA terminal show --terminal <orchestrator-handle> --json      # → result.terminal.worktreeId
ORCA terminal list --worktree id:<worktreeId> --json
```

Print `handle`, `title`, `preview`, and `lastOutputAt` per terminal, under a heading that says
plainly these are candidates rather than confirmed members — the orchestrator's own tab and
unrelated tabs land in this list too.

## 3. Offer to jump

**Live orchestrator handle.** Name the command and wait for the human to ask for it:

```text
ORCA terminal switch --terminal <handle> --json
```

Then stop. Once the human is back in the orchestrator session, that session owns the batch
again and `/orca-fan-in` in a worker pushes there as before.

**Dead orchestrator handle.** There is nothing to switch to. Print the roster, say that
in-flight pushes will land nowhere and that those workers should hand their result line to the
human instead — `/orca-fan-in` already stops and prints the line when the handle is gone — then
stop. This session reports and navigates: it names where each worker stands and leaves it there.
