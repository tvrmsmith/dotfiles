# Experiment `iws-ab-v1`

Design and analysis for the A/B run by `ab.sh`; read it when deciding the result.

## Question

This experiment asks one question: does giving a slice **one implementer** instead of **one per assignment** cost quality? Single drops the handoffs, the redispatches and most fan-in failures, so it is the flow to adopt unless split earns that overhead back. The test is therefore *is single no worse*, not *which is better*. `ab.sh` assigns the arm by hashing the slice id (SKILL.md, *Arms*), so the parent never picks it. Results count only assigned, unforced runs: a run passing `--forced` (the user directed the other arm) and a free-text slice (assigned no arm) are recorded but excluded.

## Escaped defects

`ab.sh report` derives these after handoff: the error and warning findings in the first review and test rounds of the first no-mistakes run on the slice's branch after `finish`. A repo whose ship flow is not no-mistakes reports null.

## Stopping rule

`finish` announces the stopping point, and the user decides from there. It is reached when both arms hold enough ready slices, 20 each unless `IWS_AB_STOP_AT` says otherwise. A rerun slice counts once, as its newest run. Read results with `ab.sh report`:

- Adopt single as the only flow unless split's mean kill rate beats single's by more than **0.10**, or split's mean escaped findings per slice are lower by more than **0.5**. Either margin keeps split.
- Tokens and wall-clock break ties between arms; they never outweigh a quality margin. Compare wall-clock on unattended runs, since attended time includes waiting on the user. Effective tokens weight cache reads at a tenth, roughly their price.
- Where one repo dominates one arm, check the by-repo counts in `ab.sh report` and query `metrics.jsonl` per repo before deciding, filtering on `experiment == "iws-ab-v1"`. `metrics.jsonl` lives in `$IWS_AB_DIR` (default `~/.claude/implement-with-subagents/`).

Then remove the experiment from the skill: the losing arm, the *Arms* `assign` call, `ab.sh`, this file, and step 3 of `METRICS.md`. The mutation proxy stays: it is the bias guard's third layer.

## Earlier rows

Rows without an `experiment` field predate it. Their arm `guarded` was the split shape; their arm `solo` was one implementer without parent-written expected values, so it matches neither arm. Their tokens were self-reported, and `ab.sh report` ignores them.
