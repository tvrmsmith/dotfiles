---
name: resume-work
description: Find every session that stalled while Trevor was away and start it again. `/resume-work` to sweep and restart, `/resume-work status` for the board alone.
disable-model-invocation: true
---

# Resume work

Trevor has been away and a couple of dozen sessions have been sitting. Checking each one by hand is
the problem this solves. It runs entirely on return: every session's state is already in its own
terminal scrollback, and `orca-sessions.sh` reads it.

Trevor typed `/resume-work` just now. Sweep, bucket, print the board, then branch on the argument:

| argument | do |
| --- | --- |
| nothing | clear the guard, then send, below |
| `status`, `board`, `who` | print the board and stop, leaving the guard armed |

## Sweep

```bash
~/.claude/bin/orca-sessions.sh --max-idle 100000
```

`--help` carries the fields and the flags. It needs no network, since Orca is local IPC and the
evidence is already on screen.

The `--max-idle` is the whole reason this runs wide. The script defaults to retiring a stopped
session after 6 hours, which is a sane default for a mid-day glance and wrong here: an overnight
`/afk` is ten, so the default drops every session that parked before about 3am, and a parked
session is precisely what this skill exists to surface. Age is not evidence a decision was
answered. Let the board's `idle` column carry staleness instead.

Read the JSONL, which carries the `?` rows this skill resolves. `--table` is the by-hand view for a
human at a terminal.

## Bucket

`orca-sessions.sh` sets `WORKING`, `DECIDE`, and `ERRORED` from Orca's own record of each agent's
state, so those three are already settled. It leaves the stopped ones `?`, which is the judgment
this skill brings. Read the `recap` and `call` of each `?` row and split it two ways:

| bucket | evidence | then |
| --- | --- | --- |
| `GO` | names a next step it can take alone | send the line |
| `DECIDE` | parked its remaining work for Trevor | queue it, below |
| `DONE` | says its work is finished | report it as finished |

A session that ran under `/afk` ends its last turn with an `AFK log`, and the `parked:` lines in
that log are the whole bucket test. Every item parked and nothing it can take alone is `DECIDE`,
which was all six stopped rows the day this was written. Read the log, not the summary above it.

`DECIDE` now has two entries: the script's, a live selector or permission prompt Orca reports as
`waiting`, and this one, stopped with everything parked. They read the same on the board and differ
in the tab. A `waiting` session owns its keyboard, so ESC it before anything else lands; a parked
one is already at an empty composer.

A long `turn` on a `WORKING` row is usually honest work. Every one measured so far was a deliberate
`sleep 560` CI wait, so put `turn` and `call` on the board and let Trevor read the anomaly himself.

## Clear the guard first

`/resume-work` is a return, so it ends AFK for every session, exactly as `/afk back` does:

```bash
[ -f ~/.claude/afk ] && rm -f ~/.claude/afk && echo "AFK off"
```

Leave `~/.claude/afk-sessions` alone. Each marker in there is what tells its own session, on the
next prompt Trevor types into it, that he is back.

Do this before Send. While `~/.claude/afk` stands, `~/.claude/hooks/afk-guard.sh` denies
`AskUserQuestion` and blocks the stop, so a session restarted under a live flag parks its next
decision instead of asking him for it. Report whether the flag was there, since its absence means
some other session already cleared it.

## Send

`GO` and `ERRORED` both just need their turn started again, and both hold full context in a process
no outage killed. Type this at each, per `~/.claude/docs/terminal-fanout.md`:

```text
Continue
```

An `ERRORED` session lost its turn to a failed API call, which lands between tool calls, so its
files are consistent and the same line is all it needs.

## Report

Render the board from the JSONL with the buckets resolved, one row per session, `DECIDE` first,
since those are the only ones Trevor has to act on:

```text
BUCKET  | turn   | idle | title                          | what it is waiting on
DECIDE  | -      |  38m | Approval of prior work         | discard emr-be6mp.7 or rewrite it down to the header remnant
DECIDE  | -      | 497m | Bead emr-9zt0b.31 contract     | 1Password locked mid-way, gh pr never finished
GO      | -      |  12m | no-mistakes-archon gap review  | sent, next is comparing extractor output against the Go run
WORKING | 29m7s  |   0m | restart.exempt_paths           | sleep 560, waiting on a CI rerun
DONE    | -      | 210m | Custom lint rules beads status | merged, pushed, bead closed
```

Spell out each `DECIDE` question in full under the board, since answering them is the actual work
left. Close with the count per bucket and the sessions Orca does not manage, which this never
reached.

## Walk the queue

Every `DECIDE` session gets visited, so the queue's order is yours to work out rather than his. He
settled that with "they all need to be visited". Rank by the cost of waiting:

1. A worker is still moving and could commit the parked decision itself. Ratifying it alone is the
   damage, and every minute raises the odds.
2. Everything else, heaviest first.

Then ask one `AskUserQuestion`, whether to go now, never which one:

| option | |
| --- | --- |
| `Jump to <title>` | the head of the queue, described by the question it holds |
| `Stay here` | keep working in this session |

```text
ORCA terminal switch --terminal <handle> --json
```

The switch moves Trevor's focus to that tab and leaves this session in the background, so one jump
per run is all that lands. Close by naming the rest of the queue in order, so he knows what typing
`/resume-work` again returns him to. Skip this whole section when nothing bucketed `DECIDE`.
