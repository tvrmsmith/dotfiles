# Prototype: dotfiles-co3.36, planning then wave dispatch

Throwaway. It answers whether one PRD can go from grilling to a running wave
chain in Archon, with every human touchpoint an attention gate. The decision
it fed is in `bd show dotfiles-co3.36` (`design`).

## What is here

| Path | What it is |
|------|------------|
| `setup.sh` | Builds a scratch repo, origin and tracker under `$TMPDIR`, and prints the start command |
| `workflows/plan-epic/` | Grilling as a `loop_group` ending in a `wait: attention`, a `recap` node standing in for to-spec, a scripted epic standing in for to-tickets, and a detached handoff to implement-in-waves |
| `workflows/implement-in-waves/` | A copy of co3.11's workflow with co3.38's `close-parent`, plus a per-wave seam gate and an end gate. `ready.ts`, `next.ts` and `close-parent.ts` are copied from co3.11. `ready.ts` gains a `count` field |
| `workflows/implement-slice/` | A stand-in slice: one bead fails once, one files a follow-up under the epic |

## Run it

```sh
prototypes/dotfiles-co3.36/setup.sh ['<goal text or PRD path>']
```

Then follow its printed command. It needs the grilling skill at
`$GRILLING_SKILL`, which defaults to the local mattpocock-skills checkout. Archon
resolves skills only from `.claude/skills`, so setup links the skill into the
scratch repo.

## Findings

Run 2026-11-19/20: plan-epic `242fb6b2`, then wave 1 `827d29d2`. A coordinator
agent fronted the gates for Trevor.

- **Grilling keeps its context across gates.** Each round resumed the previous
  round's Claude session (`sessionOrigin: resumed`, three chained session ids
  over three rounds). Round 2 referred to answers given in round 1.
- **Question numbers restart at Q1 every round.** That makes "Q3 yes"
  ambiguous across rounds. The fix is in the prompt: number across rounds and
  key the decision log by number.
- **The decision log carries the grilling.** A `loop_group` cannot be a session
  source for a later node, so `recap` saw only the last round's output. That
  output listed 14 decisions and, without being asked, the questions Trevor
  left unanswered when he chose "settled". to-spec can work from it. It should
  also be told that unanswered questions are not decisions.
- **The handoff works.** `handoff` launched implement-in-waves detached on the
  scripted epic and plan-epic completed. Nothing waits on the chain.
- **The seam gate renders a usable proposal.** It covers modules per slice,
  interfaces at the seams, and collisions, then the wave, dropped beads and
  not-this-epic beads.
- **Hand-answering gates is clumsy.** Trevor wanted an agent in front of the
  run, not the console or `archon workflow answer`. A coordinator chat driving
  `archon workflow wait` and `answer` worked. That led to the Q6 decision: the
  workflows stay pure Archon, and whoever fronts the run drives it through the
  CLI.

The chain then ran through waves 2 and 3 (`407464ad`, `5dd73052`):

- **"Settled" loses its answer.** The loop ended on the gate, so the text
  Trevor sent with "settled" never reached the decision log. recap kept a
  placeholder from an earlier round and listed the settled questions as
  unanswered. Trevor: "No, it misses the end". The fix is a final fold-in
  round, with the loop ending on the round's output.
- **Invented seams spread.** The stub beads had no descriptions, so the wave 1
  proposal invented `slices/a.md` and `slices/b.md`. Approval wrote them to
  the beads' notes, and wave 2's proposal then cited them as the pattern.
  Trevor: "I don't think I like that". Seams have to come from the bead or the
  code, or the proposal has to say nothing constrains the slice.
- **The gate text needed explaining.** At the first seam gate Trevor asked for
  details: what approve does, and where the seams came from.
- **Not-this-epic works, but reads oddly.** The follow-up lost its parent and
  left the wave. `wave-status` still listed it as "not started" because it
  reads `ready`, and `bd list` still drew it under the epic by its
  hierarchical id.
- **The end gate fired as designed.** B was left open, and Trevor chose stop.
  Re-dispatch and the epic closing itself were not exercised.
- **A goal naming code that does not exist traps grilling.** It asked for the
  CLI's location three rounds running. A real PRD names a real repository, so
  this is a prototype artifact.
