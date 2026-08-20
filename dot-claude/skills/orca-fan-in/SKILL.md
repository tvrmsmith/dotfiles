---
name: orca-fan-in
description: From inside a fan-out worker's session, push a one-line result back to the orchestrator that spawned it. Invoked by hand once the work is confirmed done.
disable-model-invocation: true
---

# Orca Fan-In

This session is a **worker** spawned by `/orca-fan-out`. The human has judged the work and is
releasing it. Verify the work is complete, make its record durable, then send the orchestrator
one line.

Resolve the CLI once per the `orca-cli` skill's rules; below, `ORCA` is that executable.

## 1. Check the work is done

Re-read the brief's `Expected output:` and, when it carried a `Bead:` line, the bead
(`bd show <id>`). Each thing they ask for is either produced or named to the human as not
produced. Anything still open, say what is missing and stop: the result line closes this row out
in the orchestrator's tally.

## 2. Close the bead, then push it

Bead rows only. Skip this step when the brief carried no `Bead:` line.

This is the last moment anyone is looking at this worktree, and removing a worktree deletes its
branch.

```text
bd close <id> --reason "<outcome>; commit <sha> on branch <branch>"
```

The sha and branch are required whenever this session committed anything: that sha is the only
handle left on the commit once the branch is gone, and recovery reads it. Bead already closed
without them: `bd update <id> --append-notes "commit <sha> on branch <branch>"`. Check
`close_reason` in `bd show <id> --json` either way.

Then push both records out of this worktree:

```text
git push -u origin <branch>     # the commits; skip for a tab row that committed nothing
bd dolt push                    # the bead closure
```

A push that fails on the network is transient, so retry it. A push that fails for any other
reason: report the exact error to the human and say the work still lives only in this worktree,
which they must not remove yet.

## 3. Resolve the orchestrator handle

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

## 4. Canonicalize it

Handles are aliases; the string you resolved may not be the one the runtime routes on.

```text
ORCA terminal show --terminal <resolved-handle> --json
```

Use `result.terminal.handle`. If the call fails or returns `terminal_handle_stale`, the
orchestrator's terminal is gone: tell the human, print the line you would have sent, and stop.
Fan-out re-acquires on a stale handle because it is re-finding its *own* terminal, which it can
identify; fan-in would be guessing at someone else's, and a wrong guess sends into a stranger's
session.

## 5. Compose the line

One line, opening with the literal sentinel `[fan-out]` — the orchestrator routes on it:

```text
[fan-out] <slug> ok — <one-sentence outcome>; details: <bead id / PR / branch / path>
```

- `<slug>` is this worker's task slug, taken from the `Slug:` line of the brief that launched
  this session — the orchestrator's tally matches on that exact string. When that brief opened
  with a slash command, its slots came through as the invocation's arguments, so read them from
  there. Only when the brief carried no slug, **ask the human to read the slug off this tab's
  label in the Orca sidebar** — that label is the `--title` fan-out spawned with and it holds the
  slug verbatim. Do not take it from `terminal show`: that reports the pane's activity title
  (`✳ Laptop awake fan-out task`), a different field from the tab label (`laptop-awake`), and the
  slug is not recoverable from it.
- The status is `ok`. Step 1 stopped the run on anything unfinished, so reaching here means the
  work landed.
- Keep it a pointer. The durable record is the bead, PR, or branch that `details:` names; the
  line only tells the orchestrator where to look.

## 6. Send it

```text
ORCA terminal send --terminal <canonical-handle> --text "[fan-out] ..." --enter --json
```

The line is embedded as `"[fan-out] ..."` inside a double-quoted `--text`, so keep the outcome
text free of double quotes — one splits the argument and truncates the line. Rephrase rather
than escape.

Send exactly once. Then tell the human what was sent and to which handle, and stop.

If the send fails, print the line and the canonical handle for the human to deliver by hand,
and stop.
