---
name: park
description: Bring every session on this machine to a clean stop before the network goes, and start them again after. `/park` to park, `/park back` to resume, `/park status` for the board.
disable-model-invocation: true
---

# Park

Trevor is about to lose the network, or has just got it back. This skill reaches every other Claude
session on the machine, since checking twenty of them by hand is the whole problem.

Park is a **pre-outage** move. Each session needs one live API turn to summarize and commit, so it
only works while the wire is still up. Fire it before the outage, not during.

Trevor typed `/park` just now. Branch on the argument:

| argument | do |
| --- | --- |
| nothing, or a reason (`going offline`, `flight`) | **Park**, below |
| `back`, `online`, `resume` | **Back**, below |
| `status`, `board`, `who` | Run `SWEEP.md`, print the board, stop |

## Park

Type this line at every target, per `~/.claude/docs/terminal-fanout.md`:

```text
Trevor is going offline. Read ~/.claude/skills/park/PARKING.md and follow it now.
```

Run `SWEEP.md` first, so the board tells you what each target was doing before you interrupt it.
Skip the ones already in `DONE`, since a finished session has nothing to park. Everything else gets
the line. A `WORKING` session gets it too: typed input queues and lands the moment its turn ends,
which is exactly when you want it to read this. A `STUCK` session gets an ESC first, to break it out
of the tool call that is never coming back.

Then park yourself, last, under `PARKING.md`. Report the board with a park column, and name the
sessions Orca does not manage, since nobody reached those.

## Back

Run `SWEEP.md`. A parked session sits in `GO` with a `wip(park)` commit named in its closing
paragraph, so type this line at each one:

```text
Trevor is back online. Read ~/.claude/skills/park/RESUMING.md and follow it now.
```

`DECIDE` sessions wait for Trevor, so leave them and put their questions in the report rather than
typing at them. `ERRORED` sessions are ones the outage caught mid-turn: they hold full context in
memory, so they take the same resume line, and `RESUMING.md` covers the half-finished tree.
