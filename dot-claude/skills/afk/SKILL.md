---
name: afk
description: Unattended mode for every session on this machine. `/afk 2h` or `/afk back at 4pm` to arm (8h default), `/afk back` to clear.
disable-model-invocation: true
---

# AFK

Trevor has walked away. Nobody will answer a question, approve a plan, or put a finger on the
1Password prompt until he is back. Every turn until he is: **decide, log, park**. Decide what he
would have been asked, log what you decided, park what only he can do.

**Two readers reach this file.** Trevor typed `/afk`: arm the flag, wake the parked sessions,
then run the rest. The guard sent you: the flag is already armed and other sessions are already
handled, so start at **Decide alone** and leave both alone.

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

Right after arming the flag, walk `WAKING-PARKED-SESSIONS.md` and follow it. A session that
already stopped fires neither a `Stop` nor a question, so the flag alone never reaches it.
Skip that file on `/afk back`, and skip it entirely when the guard sent you here.

## Decide alone

Make the call yourself and keep going. A question posed to an empty chair costs hours of session
time and returns nothing, so route every would-be question into the log instead.

- Torn between options: take the **reversible** one, and log the choice with its reason.
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
- Retry a failed network call once. On the second failure, park it rather than looping.

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

Write that line, on its own, once every item in the AFK log above it reads done or parked and
nothing is half-finished. If you cannot point at the log line covering what you were last
working on, you are not idle. Finish the scope you were given, then write the marker.
