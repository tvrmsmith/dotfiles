# Finishing a worktree worker spawn

Two things to clear after `terminal create` in a *new* worktree. Both are worktree-only: a tab
worker launches in this already-trusted directory and hits neither. Step 7 of the parent skill
defines when a row counts as spawned; work through both of these so that criterion can be met.

## Clear the bypass-permissions consent prompt

A new worktree *may* stop on it before the brief runs — one observed batch had one worktree stop
and another, created the same way hours later, go straight to the brief. Trust is broader than
per-worktree and its exact scope is unknown, so read for the prompt rather than assuming either
way.

Step 7's `terminal wait --for tui-idle` and the `terminal read` after it are where the prompt
shows up — the prompt is what the freshly booted worker is idling on. When
`result.terminal.tail` shows "Bypass Permissions mode" with `1. No, exit` / `2. Yes`, answer it,
then read again to confirm the brief is running:

```text
ORCA terminal send --terminal <handle> --text "2" --enter --json
ORCA terminal read --terminal <handle> --json
```

Send `2` only while that prompt is on screen — into a live Claude prompt it lands as a stray
user message.

## Reap the fallback shell

Bare `worktree create` can open a shell tab alongside the agent. List the worktree's terminals
and judge every candidate from that listing before closing anything:

```text
ORCA terminal list --worktree id:<worktreeId> --json
```

A bare shell has a generic `title` rather than the slug, a `preview` holding a shell prompt
rather than Claude's TUI, and a `lastOutputAt` still at creation time. Only a terminal matching
all three is the fallback shell — the agent tab carries the slug title and moving output.

**Handles are aliases.** The handle `terminal list` printed is not necessarily the one the
runtime routes on, so canonicalize the candidate before acting on it and close on
`result.terminal.handle`, never on the listed string:

```text
ORCA terminal show --terminal <listed-handle> --json      # → result.terminal.handle
ORCA terminal close --terminal <canonical-handle> --json
```
