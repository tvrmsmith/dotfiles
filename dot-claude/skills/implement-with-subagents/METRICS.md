# Metrics

Append one JSON line per run to `~/.claude/implement-with-subagents/metrics.jsonl` (global, so guarded-vs-solo accumulates across repos without polluting targets).

## Fields

- `arm` (guarded | solo)
- `repo`
- `redos`, count of implementer redispatches (§4 contract escalations plus §5 triage dispatches)
- `tokens` (rough)
- `mutation_kill_rate`, the headline quality signal: the fraction of the 5 mutants the slice's tests catch (see procedure below). Null on an aborted run.
- `escaped_defects`, see below

## Mutation-proxy procedure

Run once, after the §6 commit, against the run's one slice. The parent stays an orchestrator: it dispatches one mutation worker (Agent, `general-purpose`) and writes the metrics line from what the worker returns.

The worker takes **5 mutants**, one at a time: it writes one plausible-wrong implementation somewhere in the slice, runs the slice's tests, records whether they caught it, then reverts that mutant before writing the next. It returns the catch count out of 5 and leaves the tree matching the §6 commit, so the §8 handoff sees a clean tree.

Parent records `mutation_kill_rate` as that count over 5. A low kill-rate means biased or weak tests. Proxy only, no heavyweight mutation tooling.

**Aborted runs.** A run that ends with §8 `status: aborted` has no §6 commit, so there is nothing to mutate. Append the metrics line anyway, skip the mutation proxy, and leave `mutation_kill_rate` null.

## Escaped defects

`escaped_defects` is not auto-captured; they surface after handoff, in no-mistakes review/test. Leave the field to correlate later from the pipeline output.
