# Metrics

Append one JSON line per run to `~/.claude/implement-with-subagents/metrics.jsonl` (global, so guarded-vs-solo accumulates across repos without polluting targets).

## Fields

- `arm` (guarded | solo)
- `repo`
- `slices`
- `redos`
- `tokens` (rough)
- `mutation_kill_rate` — the headline quality signal (see procedure below)
- `escaped_defects` — see below

## Mutation-proxy procedure

Run once at the end of a run (not per-slice, to bound cost): for a sample of slices, generate N plausible-wrong implementations and record the fraction the slice's tests catch. Low kill-rate = biased/weak tests. Proxy only — no heavyweight mutation tooling.

## Escaped defects

`escaped_defects` is not auto-captured — they surface after handoff, in no-mistakes review/test. Leave the field to correlate later from the pipeline output.
