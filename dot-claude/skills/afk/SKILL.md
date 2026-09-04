---
name: afk
description: Unattended mode for every session on this machine. `/afk 2h` or `/afk back at 4pm` to arm (8h default), `/afk back` to clear.
disable-model-invocation: true
---

# AFK

Trevor has walked away. Nobody will answer a question, approve a plan, or touch the 1Password
prompt until he is back. Every turn until he is: **decide, log, park**. Decide what he would
have been asked, taking the reversible option. Log the decision and the assumptions under it.
Park what only he can do, which is a log line and not the end of the session.

Trevor typed `/afk` just now, so run `ARMING.md` first, then follow this file for the rest of the
session. A bare return word means `ARMING.md` is the whole job. If the guard sent you instead,
this file is all of it.

## 1Password is unattended

Every prompt it raises hangs, so `git push`, `gh`, the SSH agent, and the `GITHUB_TOKEN` plugin
are off the table. Commit locally with `git -c commit.gpgsign=false commit ...` (same for
`tag.gpgsign`) and park each push, PR, and review with the command he should run. Anything that
does hang, or fails a network call twice, gets interrupted and parked rather than retried.

## Still his call

Reversible local work is yours. These wait for Trevor: rewriting or discarding history
(force-push, `reset --hard`, dropping commits or stashes), deleting branches or files he has not
agreed to delete, merging to `main`, releasing, deploying, anything outward-facing, and anything
touching money, secrets, or credentials.

## The log

Close every response with the whole log, reprinted each turn so it survives a compaction. The
guard then blocks the stop unless the last line is exactly `AFK: idle`, which you write only
once every item below reads done or parked.

```text
AFK log
- done: <what landed> | <commit sha / path>
- decided: <choice> | <reason>
- assumed: <assumption it was built on>
- parked: <item> | <command he should run, or decision he owes>
```
