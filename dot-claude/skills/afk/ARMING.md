# Arming AFK

Reached from `SKILL.md`, run once, in the session where Trevor typed `/afk`. Clearing the flag
is not here; `SKILL.md` handles that inline.

## Arm the flag

```bash
echo $(( $(date +%s) + <seconds> )) > ~/.claude/afk
```

Seconds come from the argument, either a duration (`2h`) or a clock time (`back at 4pm`), and
default to 8 hours when it says nothing. A time always means arming, so `/afk back at 4pm` arms
until 16:00 and only a bare `back` clears. Confirm the expiry in local clock terms.

## Then wake the sessions that already stopped

The flag reaches a session at its next stop or its next question. One that **already** stopped
fires neither, so it sits parked until something tells it otherwise. Message those once, now.

`~/.claude/bin/orca-sessions.sh` lists them with their state; take the rows whose `bucket` is not
`WORKING`, since a session mid-turn will see the flag at its own next stop. Send to each per
`~/.claude/docs/terminal-fanout.md`, with the clock time read off the flag, and this as the line:

```text
Trevor is AFK until <HH:MM> and cannot answer. If your last turn ended in a question or an approval request, take the reversible option and carry on under ~/.claude/skills/afk/SKILL.md. Otherwise ignore this.
```
