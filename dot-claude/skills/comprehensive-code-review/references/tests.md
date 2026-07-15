# Test Coverage Review

Assess whether tests cover changed code. Judge **behavioral** coverage, not line counts — high line-coverage can still miss critical behavior.

When judging test quality, load the `wshp:test-best-practices` skill.

## Method

1. Find new/changed logic in diff.
2. Find tests exercising it.
3. Per behavior, ask: meaningful path tested? Edge cases? Failure modes?

## What to check

- **Critical paths** — core business logic, money/safety/data-integrity code.
- **Edge cases** — boundaries, empty/null, max/min, concurrent access.
- **Failure modes** — error handling, timeouts, invalid input, downstream failures.
- **Test quality** — tests assert real behavior, not implementation detail; meaningful failure messages; no tautological or always-passing tests; correct scoping (unit vs integration).

## Severity

Rate each gap by risk if untested code breaks:

- **Critical** — untested core logic or failure path; add tests before merge.
- **Important** — meaningful coverage gap, should cover.
- **Suggestion** — weak assertions, naming, minor missing cases.

## Output

Open with a one-line coverage judgment, then the findings. Each names the untested behavior and the test to add.