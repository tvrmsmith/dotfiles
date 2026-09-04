# Arming and clearing AFK

Reached from `SKILL.md`, run once, in the session where Trevor typed `/afk`.

## A bare return word (`back`, `done`, `I am back`)

```bash
rm -f ~/.claude/afk
```

Leave `~/.claude/afk-sessions` alone. Each marker tells its own session he is back on the next
prompt he types there, so clearing them silences the notice. Report AFK off, then stop.

## Anything else

```bash
echo $(( $(date +%s) + <seconds> )) > ~/.claude/afk
```

Seconds come from the argument, either a duration (`2h`) or a clock time (`back at 4pm`), and
default to 8 hours when it says nothing. A time always means arming, so `/afk back at 4pm` arms
until 16:00 and only a bare `back` clears. Confirm the expiry in local clock terms.

Then walk `WAKING-PARKED-SESSIONS.md` and follow it. A session that already stopped fires
neither a `Stop` nor a question, so the flag alone never reaches it.
