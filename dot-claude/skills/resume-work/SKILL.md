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
| nothing | send, below |
| `status`, `board`, `who` | print the board and stop |

## Sweep

```bash
~/.claude/bin/orca-sessions.sh
```

`--help` carries the fields and the flags. It needs no network, since Orca is local IPC and the
evidence is already on screen.

Read the JSONL, which carries the `?` rows this skill resolves. `--table` is the by-hand view for a
human at a terminal.

## Bucket

`orca-sessions.sh` sets `WORKING`, `DECIDE`, and `ERRORED` from Orca's own record of each agent's
state, so those three are already settled. It leaves the stopped ones `?`, which is the judgment
this skill brings. Read the `recap` and `call` of each `?` row and split it two ways:

| bucket | evidence | then |
| --- | --- | --- |
| `GO` | names a next step it can take alone | send the line |
| `DONE` | says its work is finished | report it as finished |

A long `turn` on a `WORKING` row is usually honest work. Every one measured so far was a deliberate
`sleep 560` CI wait, so put `turn` and `call` on the board and let Trevor read the anomaly himself.

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
BUCKET  | turn   | title                          | what it is waiting on
DECIDE  | -      | Approval of prior work         | discard emr-be6mp.7 or rewrite it down to the header remnant
DECIDE  | -      | Bead emr-9zt0b.31 contract     | 1Password locked mid-way, gh pr never finished
GO      | -      | no-mistakes-archon gap review  | sent, next is comparing extractor output against the Go run
WORKING | 29m7s  | restart.exempt_paths           | sleep 560, waiting on a CI rerun
DONE    | -      | Custom lint rules beads status | merged, pushed, bead closed
```

Spell out each `DECIDE` question in full under the board, since answering them is the actual work
left. Close with the count per bucket and the sessions Orca does not manage, which this never
reached.

## Offer the jump

A `DECIDE` session wants Trevor's own keyboard, so end by offering to put him there. Ask through
`AskUserQuestion` with up to three `DECIDE` sessions as the options, titled by `title` and described
by the question each is holding, plus `Stay here` as the last one. Skip this whole section when
nothing bucketed `DECIDE`.

```text
ORCA terminal switch --terminal <handle> --json
```

Offer one jump. The switch moves Trevor's focus to that tab and leaves this session running in the
background, where a second question would sit unread, so name the runners-up in your closing line
and let him come back for them.
