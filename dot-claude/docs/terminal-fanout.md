# Typing one line at every live Claude session

Reference for a skill that has to reach every other Claude session on this machine: `/afk` arming,
`/resume-work`. The caller brings **the line**, one sentence the receiving session reads. This file
is the mechanics of getting it typed and confirmed.

Reach for `terminal send` rather than a `SendMessage` cross-session message. An inbound peer
message lands in a held-for-approval queue a human has to release, so it never arrives while that
human is away from the keyboard. Typed terminal input has no such gate.

## Pick the targets

Resolve the CLI per the `orca-cli` skill; `ORCA` below is that executable.

```text
ORCA terminal list --json
```

Target a terminal when `agentIdentity` is `claude`, `connected` is true, `orphaned` is false, and
`lastOutputAt` (epoch ms) is inside the last 6 hours. A null `lastOutputAt` means no evidence the
session is live, so leave it out. Drop this session too, by canonicalizing
`ORCA terminal show --terminal "$ORCA_TERMINAL_HANDLE" --json` and dropping that `handle` plus
anything sharing its `tabId`, since `terminal list` hands out aliases for one tab.

When the caller already holds an exact handle list, that list replaces this whole step. Canonicalize
each handle with `terminal show` and confirm it is still connected, then carry on at the read.

## Read before you type

A session parked on an `AskUserQuestion` selector or a permission dialog is not at a text prompt,
and Enter there submits the highlighted option:

```text
ORCA terminal read --terminal <handle> --limit 200 --json   # → result.terminal.tail
```

The read decides what the target is, and only one of the four cases gets typed at:

| tail shows | meaning | action |
| --- | --- | --- |
| Claude's `❯` prompt and status bar, composer empty | parked and safe | type the line |
| a dialog footer such as `Enter to select` | a question owns the keyboard | ESC, re-read, then type |
| `❯` with text after it | an unsent draft of Trevor's | leave it, report it |
| a spinner or `esc to interrupt` | working; typed input queues and lands when the turn ends | leave it, a working session needs no telling |
| a shell prompt, not Claude's composer | Enter runs the line as a shell command | leave it |

Clear a dialog with an ESC byte, which answers nothing (Claude records `User declined to answer
questions`):

```text
ORCA terminal send --terminal <handle> --text $'\033'
```

`--interrupt` sends Ctrl-C, which a question selector ignores; ESC is what dismisses it. Clearing
the dialog wakes nothing. The typed line does that, and the re-read proves the composer is empty
first.

## Type it and confirm it

Keep the line to one line, no newlines and no apostrophes, so the quoting survives. Send the text
and the Enter as **two** calls a beat apart, since one combined call does not land:

```text
ORCA terminal send --terminal <handle> --text '<the line>'
ORCA terminal send --terminal <handle> --enter
```

Confirm each one, since `bytesWritten` only proves the bytes reached the pty. Re-read the target and
look for the line in the tail; the default read returns about 16 lines, so pass `--limit 200` or a
busy session's own output will have scrolled it away.

Report a row per target with what was done to it, call out the ones left for Trevor to unstick, and
say that sessions Orca does not manage were never reached.
