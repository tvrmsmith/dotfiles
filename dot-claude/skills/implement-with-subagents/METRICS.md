# Metrics

## The experiment

`iws-ab-v1` asks one question: does giving a slice **one implementer** instead of **one per assignment** cost quality? Single drops the handoffs, the redispatches and most fan-in failures, so it is the flow to adopt unless split earns that overhead back. The test is therefore *is single no worse*, not *which is better*. `ab.sh` assigns the arm by hashing the slice id (SKILL.md, *Arms*), so neither the parent nor the user picks it.

## Recording a run

After §6, or when an *Unattended mode* row aborts the run:

1. Run the mutation proxy below. Skip it on an aborted run.
2. Append the row:

   ```sh
   ~/.claude/skills/implement-with-subagents/ab.sh finish --run <run> --status ready \
     --branch <b> --sha <s> --killed <0-5> --redos <n> --fanin-failures <n> \
     --models '{"<assignment>":"<model>"}' [--forced] [--fit-fallback] [--note <text>]
   ```

   - `killed`: the mutation proxy's catch count.
   - `redos`: implementer redispatches, the §4 contract escalations plus the §5 triage dispatches.
   - `fanin-failures`: the §5 count.
   - An aborted run passes `--status aborted` and drops `--branch`, `--sha` and `--killed`.

The script supplies everything else from the start row and the session transcripts: arm, wall-clock, token usage across the parent and every subagent since `assign`, and the coding-standards arm the session ran under. Rows land in `~/.claude/implement-with-subagents/metrics.jsonl`. Pass on anything `finish` prints in your final report: a warning that it found no transcripts, or the notice that the stopping point is reached.

## Mutation proxy

One mutation worker (Agent, `general-purpose`) takes **5 mutants**, one at a time: it writes one plausible-wrong implementation somewhere in the slice, runs the slice's tests, records whether they caught it, then reverts it before the next. It returns the catch count out of 5 and a line per survivor. Its prompt names the slice and its tests, never the arm or how many implementers built it.

Pass that count as `--killed`, as measured. Then close each real survivor with a test, amending the §6 commit so the slice stays one commit, and pass the amended sha. An equivalent mutant needs no test; say so in `--note`.

## Escaped defects

`ab.sh report` derives these after handoff: the error and warning findings in the first review and test rounds of the first no-mistakes run on the slice's branch after `finish`. A repo whose ship flow is not no-mistakes reports null.

## Stopping rule

Decide when `finish` announces the stopping point: both arms hold enough ready slices, 20 each unless `IWS_AB_STOP_AT` says otherwise. A rerun slice counts once, as its newest run. Read results with `ab.sh report`:

- Adopt single as the only flow unless split's mean kill rate beats single's by more than **0.10**, or split's mean escaped findings per slice are lower by more than **0.5**. Either margin keeps split.
- Tokens and wall-clock break ties between arms; they never outweigh a quality margin. Compare wall-clock on unattended runs, since attended time includes waiting on the user. Effective tokens weight cache reads at a tenth, roughly their price.
- Where one repo dominates one arm, read its per-repo split before deciding.

Then delete the losing arm and this experiment from the skill.

## Earlier rows

Rows without an `experiment` field predate it. Their arm `guarded` was the split shape, their tokens self-reported, and `ab.sh report` ignores them.
