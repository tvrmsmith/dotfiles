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

Trevor typed `/afk` just now. On a bare return word (`back`, `done`) he is back, so run
`rm -f ~/.claude/afk`, report AFK off, and stop. Leave `~/.claude/afk-sessions` alone, since each
marker in there is what tells its own session, on the next prompt he types into it. On anything
else, run `ARMING.md`, then follow this file for the rest of the session. If the guard sent you
instead, this file is all of it.

## 1Password is unattended

Every prompt it raises hangs, so `git push`, `gh`, the SSH agent, and the `GITHUB_TOKEN` plugin
are off the table. Commit locally with `git -c commit.gpgsign=false commit ...` (same for
`tag.gpgsign`) and park each push, PR, and review. Anything that
does hang, or fails a network call twice, gets interrupted and parked rather than retried.

## Still his call

Reversible local work is yours, and that includes subagents executing a plan Trevor already
agreed. An assignment list he approved is a decision already made, so dispatching its workers is
executing, not orchestrating. Stalling there strands the plan half-built, which is worse than
either finishing it or never starting.

Orchestration he has not seen waits for him whole: working a wayfinder map, and any fan-out that
picks the approach, widens the scope, or starts work no agreed plan covers. Park that thread and
spend the turn on self-contained work instead. These wait for him too: rewriting or discarding history
(force-push, `reset --hard`, dropping commits or stashes), deleting branches or files he has not
agreed to delete, merging to `main`, releasing, deploying, anything outward-facing, and anything
touching money, secrets, or credentials.

## The log

Log each decision, finished item, and parked item as a row when it happens:

```bash
agent-decision-log "afk-${CLAUDE_CODE_SESSION_ID:?}" <phase> <decision> <why> <evidence> <result>
```

Read `~/.claude/skills/show-me-your-work/SKILL.md` for what a row holds. This command replaces
its `log.sh` call and keeps the log outside every worktree. The assumption a decision rests on goes
in that row's `why`. `result` is `done`, `open`, or `parked: <what it waits on>`, and an open item
closes with a later row, since the log is append-only.

Close every response with a footer that groups items by their latest row. Each item is one plain
sentence told to Trevor, not a copy of the row's cells: a parked item names what it waits on, and
a done item ends on its evidence pointer when the row has one. The first line carries the path
from `agent-decision-log --path "afk-${CLAUDE_CODE_SESSION_ID:?}"`, which is how you find the log
again after a compaction and how Trevor opens the full trail. Omit an empty group.
`/resume-work` buckets this session by the `Parked for Trevor:` group of its last turn.

```text
AFK log: <path>
- Open:
  - <item>.
- Parked for Trevor:
  - <item>, which needs <what it waits on>.
```

Once no `open` item remains, that response is the hand-back show-me-your-work describes. Audit the
log against the transcript, then have a fresh opus subagent review the trail. Put its Attention
section above the footer, led by `reviewed by claude-opus`, since this machine has no other model
family. The hand-back footer trades Open for Done, listing every item this AFK stretch finished,
and ends on a line exactly `AFK: idle`, which lets the guard pass the stop:

```text
AFK log: <path>
- Done:
  - The test suite passed (run 4121).
  - Both commits are made (a1b2c3d, e4f5a6b) and the bead notes are updated.
- Parked for Trevor:
  - Pushing the 2 commits to the open PR, which needs 1Password.
  - The merge decision.

AFK: idle
```
