---
name: resume-work
description: Find every session that stalled while Trevor was away and start it again. `/resume-work` to sweep and restart, `/resume-work status` for the board alone.
disable-model-invocation: true
---

# Resume work

Trevor has been away and a couple of dozen sessions have been sitting. Checking each one by hand is
the problem this solves. It runs entirely on return: every session's state is already in its own
terminal scrollback, and `sweep.sh` reads it.

Trevor typed `/resume-work` just now. Sweep, bucket, print the board, then branch on the argument:

| argument | do |
| --- | --- |
| nothing | send, below |
| `status`, `board`, `who` | print the board and stop |

## Sweep

```bash
~/.claude/skills/resume-work/sweep.sh
```

`--help` carries the fields and the flags. It needs no network, since Orca is local IPC and the
evidence is already on screen.

Read the JSONL, which carries the `?` rows this skill resolves. `--table` is the by-hand view for a
human at a terminal.

## Bucket

`sweep.sh` sets `bucket` where the answer is mechanical, `WORKING` off the spinner line and
`ERRORED` off an error in the tail. It leaves everything else `?`, which is the judgment this skill
brings. Read the `recap` and `call` of each `?` row and split it three ways:

| bucket | evidence | then |
| --- | --- | --- |
| `DECIDE` | ends on a question, an approval, or an `Enter to select` dialog | hand the question to Trevor |
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
