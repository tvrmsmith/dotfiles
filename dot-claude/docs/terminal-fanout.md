# Typing a line at another Claude session

What the `orca-cli` guide leaves out about `terminal send`. Load that skill for the command surface
and the CLI resolution; this is only the local knowledge on top, for `/afk` arming and
`/resume-work`.

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

Dismiss a dialog with an ESC byte, which answers nothing (Claude records `User declined to answer
questions`):

```text
ORCA terminal send --terminal <handle> --text $'\033'
```

Reach for ESC specifically: `--interrupt` sends Ctrl-C, which a question selector ignores. Clearing
the dialog wakes nothing on its own, so send the line after, once a re-read shows an empty composer.

## Confirm by re-reading

`bytesWritten` only proves the bytes reached the pty. Re-read the target and look for the line in
the tail. Pass `--limit 200`, since the default returns about 16 lines and a busy session's own
output scrolls the line away inside a second.

## Prefer typed input for this

`terminal send` puts text straight in the composer. An `orca orchestration` peer message instead
lands in a held-for-approval queue a human has to release, which is the one thing missing while
that human is away from the keyboard.
