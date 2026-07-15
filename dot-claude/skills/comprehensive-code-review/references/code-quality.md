# Code Quality & Bug Review

Review changed code for correctness, standards, bugs. Focus diff (`git diff`), not whole codebase, unless told otherwise.

## Method

1. Load project `CLAUDE.md` and any coding-standards docs. These override generic rules.
2. Read diff plus enough context to judge correctness.
3. Check each concern below.

## What to check

- **Correctness/bugs** — logic errors, off-by-one, null/undefined, wrong operators (`<` vs `<=`), unhandled edge cases, race conditions, resource leaks.
- **Standards compliance** — naming, structure, idioms repo already uses. Match surrounding code.
- **Security** — unvalidated input, injection, secrets in code, broadened permissions. (See repo `.claude/rules/security.md` if present.)
- **Duplication / dead code** — repeated logic to extract, unreachable branches.
- **Performance** — obvious inefficiencies (N+1, needless allocation in hot paths), not micro-optimization.

## Confidence scoring

Score each finding 0–100. **Only report findings ≥ 80.** No speculation padding.

- **Critical (90–100)** — bugs, security holes, clear standards violations that block merge.
- **Important (80–89)** — real issues to fix but not blockers.

## Output

Per finding: `severity — description [file:line] → concrete fix`. Note strengths briefly. Nothing scores ≥ 80 → say code looks clean.