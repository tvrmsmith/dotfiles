---
name: afk
description: Unattended mode for every session on this machine. `/afk 2h` or `/afk back at 4pm` to arm (8h default), `/afk back` to clear.
disable-model-invocation: true
---

# AFK

Trevor has walked away. Nobody will answer a question, approve a plan, or touch the 1Password
prompt until he is back. Every turn until he is: **decide, log, park**. Decide what he would
have been asked, log what you decided, park what only he can do.

Trevor typed `/afk` just now: run `ARMING.md` first. If the argument was a bare return word, that
file is the whole job and you stop there; otherwise come back and follow this one for the rest of
the session. The guard sent you instead: this file is all of it.

## Decide alone

- Torn between options: take the **reversible** one, and log the choice with its reason.
- Ambiguous spec: state the assumption in the log and implement under it.
- Genuinely blocked: park it with what it needs and move to the next piece of work. A parked
  item is a log line, not the end of the session.

## 1Password is unattended

Every prompt it raises hangs until something kills it, which takes the whole remote surface off
the table: `git push`, `gh`, the 1Password SSH agent, the `GITHUB_TOKEN` plugin.

- Commit locally with signing off: `git -c commit.gpgsign=false commit ...`, same for
  `tag.gpgsign`.
- Branch and commit freely. Park each push, PR, and review with the exact command he should run.
- A command that does hang: interrupt it, park it, move on. Rerunning hangs again.
- Retry a failed network call once, then park it.

## Still his call

Reversible local work is yours. These wait for Trevor:

- rewriting or discarding history: force-push, `reset --hard` on a shared branch, dropping
  commits or stashes
- deleting branches, worktrees, or files he has not agreed to delete
- merging to `main`, releasing, deploying
- anything outward-facing: messages, comments, issues, mail
- money, secrets, credentials, account changes

## Keep the log

Close every response with the whole log, reprinted each turn so it survives a compaction:

```text
AFK log
- done: <what landed> | <commit sha / path>
- decided: <choice> | <reason>
- assumed: <assumption it was built on>
- parked: <item> | <command he should run, or decision he owes>
```

## Stopping

The guard blocks the stop unless the response's last line is exactly `AFK: idle`. Write it once
every item in the log above reads done or parked. If you cannot point at the log line covering
what you were last working on, you are not idle. Finish the scope you were given, then write the
marker.
