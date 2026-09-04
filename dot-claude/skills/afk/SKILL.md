---
name: afk
description: Put this session, and every other session on this machine, in unattended mode while Trevor is away.
disable-model-invocation: true
---

# AFK

Trevor has walked away. Nobody will answer a question, approve a plan, or put a finger on the
1Password prompt until he is back. Keep the work already in flight moving under your own
judgment, and leave him a log he can read in thirty seconds.

## Arm the flag first

AFK is a property of Trevor, not of this session, so it lives in one file that every session on
this machine reads:

```bash
echo $(( $(date +%s) + <seconds> )) > ~/.claude/afk
```

Duration comes from the argument (`/afk 2h`, `/afk back at 4pm`); default to 8 hours when it
says nothing. `/afk back`, `/afk done`, or anything else announcing his return deletes the file
instead: `rm -f ~/.claude/afk`. Then confirm the expiry time in local clock terms and follow the
rest of this file for the rest of the session.

`hooks/afk-guard.sh` reads that file on every `Stop` and every `AskUserQuestion`, in this
session and in all the others. It denies the question and blocks the stop, so a session that
loses these instructions to a compaction still gets told. The expiry is the safety catch: a flag
he forgets to clear stops mattering on its own.

## Wake the sessions that already stopped

The flag reaches a session at its next stop or its next question. A session that **already**
stopped fires neither, so it sits parked until something tells it otherwise. Message those, once,
right after arming the flag. Skip this on `/afk back`.

Resolve the CLI per the `orca-cli` skill; `ORCA` below is that executable.

```text
ORCA terminal list --json
```

Target a terminal when `agentIdentity` is `claude`, `connected` is true, `orphaned` is false,
and `lastOutputAt` (epoch ms) is inside the last 6 hours. A null `lastOutputAt` means no
evidence the session is live: leave it out. Drop this session too, by canonicalizing
`ORCA terminal show --terminal "$ORCA_TERMINAL_HANDLE" --json` and dropping that `handle` plus
anything sharing its `tabId`, since `terminal list` hands out aliases for one tab.

**Read each target before typing at it.** A session parked on an `AskUserQuestion` selector or a
permission dialog is not at a text prompt, and Enter there submits the highlighted option:

```text
ORCA terminal read --terminal <handle> --json     # → result.terminal.tail
```

A tail ending in `Enter to select` or any other dialog footer means a dialog owns the keyboard.
Clear it with an ESC byte, which answers nothing (Claude records `User declined to answer
questions`) and hands the turn back to the agent:

```text
ORCA terminal send --terminal <handle> --text $'\033'
```

`--interrupt` sends Ctrl-C, which a question selector ignores; ESC is what dismisses it. That
alone is usually enough: the agent's turn ends, `Stop` fires, and the armed guard turns it
around. Read once more to confirm the dialog cleared.

For a session at an ordinary prompt, type one line, no newlines and no apostrophes so the
quoting survives. Send the text and the Enter as **two** calls, since one combined call does not
land:

```text
ORCA terminal send --terminal <handle> --text 'Trevor is AFK until <HH:MM> and cannot answer. If your last turn ended in a question or an approval request, pick the option you would defend and carry on under ~/.claude/skills/afk/SKILL.md. Otherwise ignore this.'
ORCA terminal send --terminal <handle> --enter
```

Sending to a session that turns out to be mid-task is harmless: the input queues and it reads it
when it finishes, and the closing sentence makes it a no-op for anything that was not parked.

Reach for `terminal send` rather than a `SendMessage` cross-session message. An inbound peer
message lands in a held-for-approval queue the receiving human has to release, so it never
arrives while that human is the one who is away. Typed terminal input has no such gate.

Report the count told, then say that sessions Orca does not manage were not reached.

## Decide alone

Make the call yourself and keep going. A question posed to an empty chair costs hours of session
time and returns nothing, so route every would-be question into the log instead.

- Torn between options: take the one that is easiest to undo, and log the choice with its
  reason.
- Ambiguous spec: state the assumption in the log and implement under it.
- Something genuinely blocked: park it, log what it needs, and move to the next piece of work.
  A parked item is a log line, not the end of the session.

## 1Password is unattended

Every prompt it raises waits for a fingerprint that is not coming, so the command hangs until
something kills it. That takes the whole remote surface off the table: `git push`, `gh`, the
1Password SSH agent, the `GITHUB_TOKEN` shell plugin.

- Commit locally with signing off:
  `git -c commit.gpgsign=false commit ...`, and `git -c tag.gpgsign=false tag ...`.
- Branch and commit as much as the work needs. Push, PRs, and reviews wait for his return; park
  each one with the exact command he should run.
- A command that does stall on a prompt: interrupt it, park it, move on. Rerunning hangs again.
- Network drops on this laptop are transient, so retry a failed network call once. On the second
  failure, park it rather than looping.

## Still his call

Reversible local work is yours. These wait for Trevor even where a path around 1Password exists:

- rewriting or discarding history: force-push, `reset --hard` on a shared branch, dropping
  commits or stashes
- deleting branches, worktrees, or files he has not agreed to delete
- merging to `main`, releasing, or deploying
- anything outward-facing: messages, comments, issues, mail
- money, secrets, credentials, account changes

## Keep the log

Close every response with the cumulative log, reprinted in full each turn so it survives a
compaction:

```text
AFK log
- done: <what landed> — <commit sha / path>
- decided: <choice> — <reason>
- assumed: <assumption it was built on>
- parked: <item> — <command he should run, or decision he owes>
```

## Stopping

The guard blocks a stop unless the response's final line is exactly:

```text
AFK: idle
```

Write that line, on its own, once the work is genuinely finished: the log above it is the
handoff, and the session parks until Trevor is back. Inventing new scope to avoid the marker
gives him more to review, not less.
