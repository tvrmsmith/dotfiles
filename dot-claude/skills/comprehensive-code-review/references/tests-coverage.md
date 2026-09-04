# Test Coverage Review

Does the changed behavior have tests? Judge **behaviorally**, not by line counts.

## Method

1. Find new/changed logic in diff.
2. Find tests exercising it.
3. Check each behavior against the concerns below.

Done when every new/changed behavior in the diff is accounted for — covered, or reported as a gap.

## What to check

- **Critical paths** — core business logic, money/safety/data-integrity code.
- **Edge cases** — boundaries, empty/null, max/min, concurrent access.
- **Failure modes** — error handling, timeouts, invalid input, downstream failures.

## Severity

Rate each gap by risk if untested code breaks:

- **Critical** — untested core logic or failure path; add tests before merge.
- **Important** — meaningful coverage gap, should cover.
- **Suggestion** — minor missing cases.

## Output

Each finding names the untested behavior and the test to add.
