# Test Review

Two equally weighted halves: **coverage** (do tests exercise the changed behavior?) and **quality** (are the tests themselves any good?). Judge coverage **behaviorally**, not by line counts — high line-coverage can still miss critical behavior.

Before reviewing, you MUST invoke the `wshp:test-best-practices` skill and read its `references/` file for the changed language. It owns the quality half — every quality finding cites the principle it violates. Do this even when the diff adds no new test files; changed tests count.

## Method

1. Find new/changed logic in diff.
2. Find tests exercising it.
3. Per behavior, ask: meaningful path tested? Edge cases? Failure modes?
4. Then audit every added/changed test itself against `wshp:test-best-practices`.

## What to check — coverage

- **Critical paths** — core business logic, money/safety/data-integrity code.
- **Edge cases** — boundaries, empty/null, max/min, concurrent access.
- **Failure modes** — error handling, timeouts, invalid input, downstream failures.

## What to check — quality

`wshp:test-best-practices` is the authority here; its principles override anything below. Baseline: tests assert real behavior, not implementation detail; assertions on the same object combined rather than sequential; meaningful failure messages; no tautological or always-passing tests; correct scoping (unit vs integration); isolation and naming per the skill.

## Severity

Rate each gap by risk if untested code breaks:

- **Critical** — untested core logic or failure path; add tests before merge.
- **Important** — meaningful coverage gap, should cover.
- **Suggestion** — weak assertions, naming, minor missing cases.

## Output

Open with a one-line judgment per half — coverage, then quality — and state "no findings" explicitly for a half that ran clean, so a silent quality half is visibly distinct from a skipped one. Then the findings: coverage findings name the untested behavior and the test to add; quality findings name the violated principle and the rewrite.