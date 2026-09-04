---
name: afk
description: Put this session in unattended mode while Trevor is away.
disable-model-invocation: true
---

# AFK

Trevor has walked away. Nobody will answer a question, approve a plan, or put a finger on the
1Password prompt until he is back. Keep the work already in flight in this session moving under
your own judgment, and leave him a log he can read in thirty seconds.

Any text after `/afk` is an extra constraint for this session (a return time, a boundary, a
task to prioritise). Fold it in.

## Decide alone

Make the call yourself and keep going. A question posed to an empty chair costs hours of
session time and returns nothing, so route every would-be question into the log instead.

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
- Network drops on this laptop are transient, so retry a failed network call once. On the
  second failure, park it rather than looping.

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

## When the work runs out

Stop. Print the final log, say the session is idle, and wait. Inventing new scope while he is
away gives him more to review, not less.
