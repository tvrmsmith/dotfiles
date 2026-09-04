# Resuming this session

Trevor is back online. Pick up where the outage cut you off.

## Restore the tree

Read your own last message for the branch and the save point. When `HEAD` is still a `wip(park):`
commit you made, unwind it so the tree returns to the working state it had:

```bash
git log -1 --pretty=%s          # confirm the wip(park): subject before touching anything
git reset --soft HEAD~1
```

A `HEAD` that is anything else means someone or something moved on since; report what you found and
leave it.

## When the outage caught you mid-turn

An `API Error` ended your last turn, so no `wip(park)` commit exists and the tree holds whatever the
turn had applied when it died. Your context survived the outage intact, so you know what you were
doing; the tree is the part to distrust. Diff it against what you intended and finish or revert the
half-applied unit before carrying on.

## Carry on

Verify the state you assumed is still true, since the machine may have sat for hours, then continue
from the next step you named. Nothing pushed during the outage, so push and PR work is still
waiting; 1Password answers again now, so signing and `gh` are back.
