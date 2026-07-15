# Code Quality & Bug Review

Review changed code for correctness, standards, bugs. Focus diff (`git diff`), not whole codebase, unless told otherwise.

## Method

1. Read diff plus enough context to judge correctness.
2. Check each concern below.

## What to check

- **Correctness/bugs** — logic errors, off-by-one, null/undefined, wrong operators (`<` vs `<=`), unhandled edge cases, race conditions, resource leaks.
- **Standards compliance** — naming, structure, idioms repo already uses. Match surrounding code.
- **Security** — unvalidated input, injection, secrets in code, broadened permissions. (See repo `.claude/rules/security.md` if present.)
- **Duplication / dead code** — repeated logic to extract, unreachable branches.
- **Performance** — obvious inefficiencies (N+1, needless allocation in hot paths), not micro-optimization.

## What to report

Report only high-confidence findings — no speculation padding. Label each by the shared severity; here Critical is a bug, security hole, or clear standards violation that blocks merge. Nothing high-confidence → say code looks clean.