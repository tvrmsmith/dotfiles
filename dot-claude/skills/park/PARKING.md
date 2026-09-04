# Parking this session

Trevor is about to lose the network. Reach a clean stop while the API still answers, so nothing of
yours is mid-turn when the wire goes. Everything below is local; the network is the thing you are
racing.

## Finish the current thought

Stop at the next natural boundary rather than the current one. A half-applied change is worse to
come back to than a finished small one, so if one more edit completes the unit you were making,
make it. Start nothing new.

Running subagents get one chance to land. Wait for anything already dispatched, since a subagent
mid-flight when the API dies leaves you a result you never see.

## Commit what is dirty

1Password may be unreachable too, and its prompt hangs with nobody there to approve it, so sign
nothing and push nothing:

```bash
git -c commit.gpgsign=false commit -am "wip(park): <what is in the tree>"
```

Add untracked files that belong to the work first. A clean tree needs no commit; say so instead.
A rebase or merge already in progress stays in progress: record which, and leave it alone.

The commit is a save point, not history. `RESUMING.md` unwinds it with `git reset --soft HEAD~1`
so the tree comes back exactly as it is now, which is why the subject carries the `wip(park):`
marker.

## Stop with a paragraph

Close with one paragraph, since it is the only thing you can count on reading back. Name the
branch, the `wip(park)` sha, the goal, and the exact next step. Write the next step as an
instruction to yourself, specific enough to act on cold.
