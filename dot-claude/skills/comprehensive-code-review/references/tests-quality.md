# Test Quality Review

Are the added/changed tests themselves any good?

`coding-standards:test-best-practices` owns this review — read its `references/` file for the changed language, and cite the principle each finding violates. Review changed tests even when the diff adds no new test files.

## Method

Audit every added/changed test in the diff against `coding-standards:test-best-practices`.

Done when every added/changed test has been audited.

## Severity

- **Critical** — tautological or always-passing test; asserts nothing real.
- **Important** — asserts implementation detail, wrong scope, broken isolation.
- **Suggestion** — weak assertions, naming, structure.

## Output

Each finding names the violated principle and the rewrite.
