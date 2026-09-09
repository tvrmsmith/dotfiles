# Arming AFK

Reached from `SKILL.md`, run once, in the session where Trevor typed `/afk`. Clearing the flag
is not here; `SKILL.md` handles that inline.

## One command

```bash
~/.claude/bin/afk-arm.sh "<the argument, verbatim>"
```

It resolves the return time, writes `~/.claude/afk`, and types the AFK line into every session
that has already stopped, since one that stopped fires neither a stop nor a question and would
sit parked until told otherwise. A session Orca reports as WORKING is left alone; it meets the
flag at its own next stop.

Pass the argument as it was typed. The script reads a duration (`2h`, `90m`, `1h30m`) or a clock
time (`4pm`, `16:00`, `9am`) out of surrounding prose, honours `tomorrow`, and defaults to 8
hours when the argument says nothing. A time always means arming, so `/afk back at 4pm` arms
until 16:00 and only a bare `back` clears.

Read its report and pass on to Trevor what it says: the expiry in local clock terms, and any
session it skipped or failed. Then continue with `SKILL.md`.

## When it exits 2

It could not find a time in the argument and wrote nothing. Decide the clock time yourself, then
re-run with a bare `4pm` or `2h`.

## When it reports a skip

Each skip is a session that did not get the line, so treat it as one more thing Trevor is away
from:

- `unsent draft in composer` — Trevor's own typing is sitting there. Leave it, and report it.
- `no Claude composer found` — the pane render was too collapsed to classify. Leave it.
- `working` — expected, and fine.

## When it reports FAILED

The line reached the pty and never appeared. Re-run the script; it is safe to run twice, and a
session that already got the line reads a duplicate as a no-op.
