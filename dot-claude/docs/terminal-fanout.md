# Typing a line at another Claude session

What the `orca-cli` guide leaves out about `terminal send`. Load that skill for the command surface
and the CLI resolution; this is only the local knowledge on top, for `/afk` arming and
`/resume-work`.

`~/.claude/bin/afk-arm.sh` already implements every rule below for the `/afk` fan-out. Read this
when you are typing a line by hand, or when changing that script.

## Read before you type

The guide says to read before sending unless the next input is obvious. With a Claude TUI on the
other end it is never obvious, because a session sitting on an `AskUserQuestion` selector or a
permission dialog is not at a text prompt, and Enter there submits whatever option is highlighted.

```text
ORCA terminal read --terminal <handle> --limit 200 --json   # → result.terminal.tail
```

The read sorts the target into one of four states, and one of them takes the line:

| tail shows | meaning | action |
| --- | --- | --- |
| Claude's `❯` prompt and status bar, composer empty | parked and safe | send the line |
| a dialog footer such as `Enter to select` | a question owns the keyboard | ESC, re-read, then send |
| `❯` with text after it | an unsent draft of Trevor's | leave it, report it |
| a shell prompt rather than Claude's composer | Enter runs the line as a shell command | leave it |

Read the **last** `❯` line, not any `❯` line. The transcript prefixes every past user message with
the same glyph, so a scrollback full of them reads as row three and skips a session that is
actually parked and safe.

Dismiss a dialog with an ESC byte, which answers nothing (Claude records `User declined to answer
questions`):

```text
ORCA terminal send --terminal <handle> --text $'\033'
```

Reach for ESC specifically: `--interrupt` sends Ctrl-C, which a question selector ignores. Clearing
the dialog wakes nothing on its own, so send the line after, once a re-read shows an empty composer.

### ESC lands in vim NORMAL

With vim mode on, the same ESC that dismisses a dialog also leaves the composer in NORMAL, where
the line you send next is read as commands rather than text. The status bar says which mode it is
in. Return to INSERT and clear whatever the dialog left before sending:

```text
ORCA terminal send --terminal <handle> --text 'i'        # NORMAL or VISUAL → INSERT
ORCA terminal send --terminal <handle> --text $'\025'    # ctrl-U, clears the composer
```

Send `i` only when the bar shows `-- NORMAL --` or `-- VISUAL --`. In INSERT it types a literal
`i`.

### `tui-idle` cannot stand in for the read

```text
ORCA terminal wait --terminal <handle> --for tui-idle --timeout-ms 1 --json
```

It answers one question cheaply and well: a session mid-turn gives `null`, one at rest gives `true`,
either way in about 200ms, so the timeout is a deadline rather than a sleep. What it will not do is
separate rows two and three of the table above. **A session sitting on a live `AskUserQuestion`
selector reports `true`.** Only the read sees the dialog.

Read `.result.wait.satisfied`. The shorter `.result.satisfied` silently yields `null`, which reads
exactly like a busy session.

## Send the text and the Enter as two calls

```text
ORCA terminal send --terminal <handle> --text "<line>"
ORCA terminal send --terminal <handle> --enter
```

A combined `--text ... --enter` usually lands, and it survived every state deliberately tested:
idle, mid-turn, and just after an ESC. It has still been observed dropping twice in a row, with the
text never reaching the composer, in a run that no later attempt reproduced. The two-call form has
never been seen to fail, so pay the extra call.

Then confirm, below. A send that reports `ok` and vanishes is the failure this guards.

## Confirm by re-reading

`bytesWritten` only proves the bytes reached the pty. Re-read the target and look for the line in
the tail. Pass `--limit 200`, since the default returns about 16 lines and a busy session's own
output scrolls the line away inside a second.

## Prefer typed input for this

`terminal send` puts text straight in the composer. An `orca orchestration` peer message instead
lands in a held-for-approval queue a human has to release, which is the one thing missing while
that human is away from the keyboard.
