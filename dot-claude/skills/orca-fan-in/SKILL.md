---
name: orca-fan-in
description: From inside a fan-out worker's session, close the tracker row and push a one-line result back to the orchestrator that spawned it. Invoked by hand once the work is confirmed done.
disable-model-invocation: true
---

# Orca Fan-In

This session is a **worker** spawned by `/orca-fan-out`. The human has judged the work and is
releasing it. Verify the work is complete, make its record durable, then send the orchestrator
one line.

Resolve the CLI once per the `orca-cli` skill's rules; below, `ORCA` is that executable.

## 1. Check the work is done

Re-read the brief's `Expected output:` and, when it names one, the **tracker row** this work
belongs to. Read the row before judging the work: it often carries acceptance detail the brief
compressed.

The brief names its row in whatever tracker the repo uses, so read for the reference rather than
for one label: a `Bead:` line, a GitHub issue number, a Jira or Linear key. The repo's own
`CLAUDE.md` says which tracker it is on. A brief may name several rows, or none.

Each thing the brief asks for is either produced or named to the human as not produced. Anything
still open, say what is missing and stop: the result line closes this row out in the
orchestrator's tally.

## 2. Close the row, then make it durable

Fan-in is user-invocable only, so reaching it is the human's approval to close the row.

Two cases skip the close and go straight to the commits. Say which one applied.

- The brief names no row.
- The brief reserves the close: "leave the issue open", "I close it myself". That instruction
  outranks the approval fan-in carries, so report the row as ready to close and leave it open.

Whatever the tracker, the closing note carries the same three things: the outcome, the commit
sha, and the branch. This is the last moment anyone is looking at this worktree, and removing a
worktree deletes its branch, so that sha is the only handle left on the commit and recovery reads
it. Write the sha and branch whenever this session committed anything.

**Beads.** The closure lives in this worktree until pushed, so it needs both commands.

```text
bd close <id> --reason "<outcome>; commit <sha> on branch <branch>"
bd dolt push
```

Already closed without the sha: `bd update <id> --append-notes "commit <sha> on branch <branch>"`.

**GitHub Issues.** Already durable once the call returns, so there is nothing to push.

```text
gh issue close <number> -R <owner>/<repo> --reason completed --comment "<outcome>; commit <sha> on branch <branch>"
```

Closing through a PR keyword instead is the same job done earlier. When the merged PR already
closed the row, say so rather than re-closing it.

**Any other tracker.** Use its own CLI or API with the same note, and name to the human which
command you ran, since a tracker this skill has not met is where a wrong guess hides.

Then confirm the close landed rather than trusting the exit code: `bd show <id> --json` for
`close_reason`, `gh issue view <number> --json state` for `CLOSED`, the equivalent read elsewhere.

Then push the commits out of this worktree:

```text
git push -u origin <branch>
```

Skip it for a row that committed nothing, and for a branch already pushed and merged. A push that
fails on the network is transient, so retry it. A push that fails for any other reason: report the
exact error to the human and say the work still lives only in this worktree, which they must not
remove yet.

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
[fan-out] <slug> ok — <one-sentence outcome>; details: <tracker row / PR / branch / path>
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
- Keep it a pointer. The durable record is the tracker row, PR, or branch that `details:` names;
  the line only tells the orchestrator where to look.
- Name any deviation from the brief, including one the human directed live. The orchestrator
  reads `ok` as the brief met verbatim, so a silent deviation is recorded as a clean run.

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
