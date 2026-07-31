---
name: orca-fan-in
description: From inside a fan-out worker's session, push a one-line result back to the orchestrator that spawned it. Invoked by hand once the work is confirmed done.
disable-model-invocation: true
---

# Orca Fan-In

This session is a **worker** spawned by `/orca-fan-out`. The human has judged the work and is
releasing it. Resolve the orchestrator's terminal handle, then send it one line.

Resolve the CLI once per the `orca-cli` skill's rules; below, `ORCA` is that executable.

## 1. Resolve the orchestrator handle

A fallback chain, not a branch — try each in order and take the first that yields a handle.

**Environment** (how a tab worker knows). Fan-out inline-prefixed the handle onto the launch
command, so it is in this session's environment:

```text
echo "$ORCA_FANOUT_ORCHESTRATOR"
```

**Worktree provenance** (how a worktree worker knows). This worktree's own record names the
terminal that created it:

```text
ORCA worktree show --worktree current --json
```

**This fallback applies only when this session's own worktree is this worker's worktree** — that
is, `result.worktree.displayName` equals the `Slug:` line of the brief that launched this
session, the same string fan-out passed to `worktree create --name`. A tab worker sits in the
orchestrator's own worktree, so its provenance names whoever created *that* worktree: a stranger,
not the orchestrator.

If the two differ, or the brief carried no `Slug:` line, there is nothing to check against and
this fallback does not apply.

When `displayName` matches the brief's slug, take
`result.worktree.cliProvenance.callerTerminalHandle`, and only that field — the parent worktree
can hold several agent terminals, and this one alone names the terminal that spawned this
session.

If no fallback yields a handle — the environment is empty and either this fallback does not apply
or the provenance field is absent — the chain has no answer. Say so, hand the result to the human
as text, and stop. Sending into the wrong session is worse than not sending.

## 2. Canonicalize it

Handles are aliases; the string you resolved may not be the one the runtime routes on.

```text
ORCA terminal show --terminal <resolved-handle> --json
```

Use `result.terminal.handle`. If the call fails or returns `terminal_handle_stale`, the
orchestrator's terminal is gone: tell the human, print the line you would have sent, and stop.
Fan-out re-acquires on a stale handle because it is re-finding its *own* terminal, which it can
identify; fan-in would be guessing at someone else's, and a wrong guess sends into a stranger's
session.

## 3. Compose the line

One line, opening with the literal sentinel `[fan-out]` — the orchestrator routes on it:

```text
[fan-out] <slug> <ok|failed|blocked> — <one-sentence outcome>; details: <bead id / PR / branch / path>
```

- `<slug>` is this worker's task slug, taken from the `Slug:` line of the brief that launched
  this session — the orchestrator's tally matches on that exact string. When that brief opened
  with a slash command, its slots came through as the invocation's arguments, so read them from
  there. Only when the brief carried no slug, **ask the human to read the slug off this tab's
  label in the Orca sidebar** — that label is the `--title` fan-out spawned with and it holds the
  slug verbatim. Do not take it from `terminal show`: that reports the pane's activity title
  (`✳ Laptop awake fan-out task`), a different field from the tab label (`laptop-awake`), and the
  slug is not recoverable from it.
- `ok` / `failed` / `blocked` is the human's verdict, not a self-assessment. Ask when it is
  unclear.
- Keep it a pointer. The durable record is the bead, PR, or branch that `details:` names; the
  line only tells the orchestrator where to look.

**Before sending, make the bead survive this worktree.** If this session committed anything, its
bead's close reason must name the **commit sha and branch** — check `close_reason` in
`bd show <id> --json`. Not closed yet: `bd close <id> --reason "<outcome>; commit <sha> on branch
<branch>"`. Already closed without it: `bd update <id> --append-notes "commit <sha> on branch
<branch>"`. Removing this
worktree deletes its branch, and the sha in that reason is then the only handle left on the
commit. Fan-in is the last moment anyone is looking.

## 4. Send it

```text
ORCA terminal send --terminal <canonical-handle> --text "[fan-out] ..." --enter --json
```

The line is embedded as `"[fan-out] ..."` inside a double-quoted `--text`, so keep the outcome
text free of double quotes — one splits the argument and truncates the line. Rephrase rather
than escape.

Send exactly once. Then tell the human what was sent and to which handle, and stop.

If the send fails, print the line and the canonical handle for the human to deliver by hand,
and stop.
