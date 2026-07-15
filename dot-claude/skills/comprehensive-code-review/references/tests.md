# Test Coverage Review

Assess whether tests cover changed code. Judge **behavioral** coverage, not line counts — high line-coverage can still miss critical behavior.

## Method

1. Find new/changed logic in diff.
2. Find tests exercising it.
3. Per behavior, ask: meaningful path tested? Edge cases? Failure modes?

## What to check

- **Critical paths** — core business logic, money/safety/data-integrity code.
- **Edge cases** — boundaries, empty/null, max/min, concurrent access.
- **Failure modes** — error handling, timeouts, invalid input, downstream failures.
- **Test quality** — tests assert real behavior, not implementation detail; meaningful failure messages; no tautological or always-passing tests; correct scoping (unit vs integration).

## Criticality rating

Rate each gap 1–10 by risk if untested code breaks:

- **Critical (8–10)** — untested core logic or failure path; add tests before merge.
- **Important (5–7)** — meaningful gap, should cover.
- **Quality (1–4)** — weak assertions, naming, minor missing cases.

## Output

- **Summary** — overall coverage judgment.
- **Critical gaps (8–10)** — what untested, why matters, what test to add.
- **Important gaps (5–7)**.
- **Quality issues** — brittle/weak tests.
- **Strengths** — what well covered.

Each item: `description [file:line] → suggested test`.