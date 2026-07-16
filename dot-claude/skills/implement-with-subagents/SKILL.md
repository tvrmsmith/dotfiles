---
name: implement-with-subagents
description: Orchestrate a spec/tickets implementation across subagents — parent plans and delegates, workers do TDD on a controllable model, then hand off to no-mistakes.
disable-model-invocation: true
---
# Implement With Subagents

Runs Matt Pocock's `implement` recipe with the actual work in **subagents**, because the parent can't downgrade its own model mid-task — that's why subagents exist at all here. The **parent is an orchestrator only**: it plans, agrees seams, picks models, injects expected values, and decides. **Workers** run the code via TDD on a model you control. The skill ends when the work is TDD-implemented and committed on a feature branch, then stops and hands off to `no-mistakes` (see §8).

## Modes

- **guarded** (default) — anti-bias arm: the parent injects independently-derived expected values so the implementer inherits a fixed target it can't shape to its own code.
- **`--solo`** — one worker does everything (contract, test, impl), no injection. Cheaper/faster when bias isn't a concern, and doubles as the **metrics baseline** for comparing against guarded.

## Bias guard (no dedicated auditor)

Testing bias is caught in three layers, so no per-slice test-auditor is needed:
1. **guarded expected-value injection** — during impl, above.
2. **comprehensive-code-review Tests aspect** — downstream, via no-mistakes (catches tautological / impl-coupled / weak-assertion tests).
3. **mutation-proxy metric** (see METRICS.md).

Note: layers 2–3 only fire because no-mistakes is always run. If a run skips the pipeline, guarded injection (layer 1) is the *only* in-skill guard.

## 1. Parse input

Target is a spec, tickets, or a task description (natural language, path, or ticket IDs). Flags: `--solo`, per-slice model overrides. Absent overrides are decided in §2–§3.

## 2. Plan and decompose

Parent reads the spec and relevant code, then produces:
- The **seams** to test at (public boundaries only).
- An ordered set of **vertical slices** — one seam → one test → minimal implementation each.
- A **size check** per slice: each must comfortably fit one worker context window. If a slice looks too big, split it before dispatch. (You are orchestrating live and judge this.)
- A **parallelism** call: which slices are independent (disjoint files, no shared state) and can run across multiple workers concurrently.

Done when every slice has a named seam, a size-OK check, and a parallel/sequential tag.

## 3. Model selection

Judge the difficulty of the work and **recommend** an implementer model via `AskUserQuestion`, offering alternatives + Other, with your reasoning. Implementers lean cheaper (they only make an existing test green); re-recommend for a later slice that turns out far harder/easier. Wait for the pick — never assume. Multiple implementers may run on different models if slices vary in difficulty.

## 4. Agree seams

Per `tdd`: no test at an unconfirmed seam. Present the §2 seam list and confirm before any TDD cycle. Parent's job.

## 5. TDD loop, per slice

Parent drives the loop and carries adaptive state between cycles (each test is a tracer bullet responding to what the last taught — vertical slices, one at a time, never all-tests-then-all-impl). The parent is the TDD **loop driver** and invokes the `tdd` skill itself to carry the red-green rules and anti-patterns; workers invoke `tdd` too when they write tests.

**guarded** — per slice:
- Parent writes the contract and expected values (sourced from spec / worked example / known-good literal).
- Dispatch an implementer worker (Agent, `general-purpose`, chosen model) given only: the slice, the contract + expected values, and an instruction to **load `coding-standards` itself** (subagents don't inherit the parent's loaded skills). It writes the failing test to the expectation, then the minimum code to green it, running typecheck + the single test file in-loop. It preserves every assertion and the injected expected values as given; if it judges the contract wrong, it stops and escalates to the parent.

**`--solo`** — same dispatch, but the worker writes the contract, test, and impl itself; no parent expected-value injection.

**Overflow:** a worker that finds its slice too big returns "too big" with a sub-slice suggestion instead of pushing through; parent re-decomposes.

**Parallel slices:** independent slices fan across multiple workers (parallel per §2).

A slice is done when its test is green and typecheck passes; the loop is done when every slice is green.

## 6. Commit

Commit on a **feature branch** (create one if on the default branch — no-mistakes validates committed history on a non-default branch).

## 7. Metrics

Record one metrics line per run — see `METRICS.md` for the schema and the mutation-proxy procedure.

## 8. Stop and hand off

Do not run review/test/lint/push/PR/CI. Report the work is ready and give the `--intent` string for no-mistakes (what the user set out to accomplish, enriched with the decisions/tradeoffs made). The user drives `no-mistakes` themselves — it has gates only they should answer.
