# Arming and clearing AFK

Reached from `SKILL.md`, run once, in the session where Trevor typed `/afk`.

## A bare return word (`back`, `done`, `I am back`)

```bash
rm -f ~/.claude/afk
```

Leave `~/.claude/afk-sessions` alone. Each marker tells its own session he is back on the next
prompt he types there, so clearing them silences the notice. Report AFK off, then stop. Nothing
below applies.

## Anything else

```bash
echo $(( $(date +%s) + <seconds> )) > ~/.claude/afk
```

Seconds come from the argument, either a duration (`2h`) or a clock time (`back at 4pm`), and
default to 8 hours when it says nothing. A time always means arming, so `/afk back at 4pm` arms
until 16:00 and only a bare `back` clears. Confirm the expiry in local clock terms.

## Then wake the sessions that already stopped

The flag reaches a session at its next stop or its next question. One that **already** stopped
fires neither, so it sits parked until something tells it otherwise. Message those once, now.

Resolve the CLI per the `orca-cli` skill; `ORCA` below is that executable.

```text
ORCA terminal list --json
```

Target a terminal when `agentIdentity` is `claude`, `connected` is true, `orphaned` is false,
and `lastOutputAt` (epoch ms) is inside the last 6 hours. A null `lastOutputAt` means no
evidence the session is live, so leave it out. Drop this session too, by canonicalizing
`ORCA terminal show --terminal "$ORCA_TERMINAL_HANDLE" --json` and dropping that `handle` plus
anything sharing its `tabId`, since `terminal list` hands out aliases for one tab.

**Read each target before typing at it.** A session parked on an `AskUserQuestion` selector or a
permission dialog is not at a text prompt, and Enter there submits the highlighted option:

```text
ORCA terminal read --terminal <handle> --limit 200 --json   # → result.terminal.tail
```

The read decides what the target is, and only one of the four cases gets typed at:

| tail shows | meaning | action |
| --- | --- | --- |
| Claude's `❯` prompt and status bar, composer empty | parked and safe | type the line |
| a dialog footer such as `Enter to select` | a question owns the keyboard | ESC, re-read, then type |
| `❯` with text after it | an unsent draft of Trevor's | leave it, report it |
| a spinner, `esc to interrupt`, or a shell prompt | working, or not Claude's composer at all — at a shell the line is a command Enter runs | leave it |

Clear a dialog with an ESC byte, which answers nothing (Claude records `User declined to answer
questions`):

```text
ORCA terminal send --terminal <handle> --text $'\033'
```

`--interrupt` sends Ctrl-C, which a question selector ignores; ESC is what dismisses it. Clearing
the dialog wakes nothing. The typed line does that, and the re-read proves the composer is empty
first.

Type one line, no newlines and no apostrophes so the quoting survives, with the clock time read
off the flag. Send the text and the Enter as **two** calls a beat apart, since one combined call
does not land:

```text
ORCA terminal send --terminal <handle> --text 'Trevor is AFK until <HH:MM> and cannot answer. If your last turn ended in a question or an approval request, take the reversible option and carry on under ~/.claude/skills/afk/SKILL.md. Otherwise ignore this.'
ORCA terminal send --terminal <handle> --enter
```

Reach for `terminal send` rather than a `SendMessage` cross-session message. An inbound peer
message lands in a held-for-approval queue the receiving human has to release, so it never
arrives while that human is the one who is away. Typed terminal input has no such gate.

Confirm each one, since `bytesWritten` only proves the bytes reached the pty. Re-read the target
and look for the line in the tail; the default read returns about 16 lines, so pass
`--limit 200` or a busy session's own output will have scrolled it away.

Report a row per target with what was done to it, call out the ones left for Trevor to unstick,
and say that sessions Orca does not manage were never reached.
