---
name: comprehensive-code-review
description: Reviews changed code across quality, tests, error handling, comments, type design, and simplification. Use when asked to review a PR, a diff, or changes before commit.
---
# Comprehensive Code Review

Review changed code across up to six aspects, each backed by reference doc in `references/`. Run aspects that apply, then aggregate.

## 1. Scope

Default target: unstaged + staged changes (`git diff` and `git diff --cached`). PR exists (`gh pr view`) → use its diff. Honor explicit scope caller gives.

## 2. Pick applicable aspects

Caller named specific aspects (e.g. "review error handling and tests") → run only those. Else select from changed files what applies:

| Aspect | Reference | Apply when |
|--------|-----------|------------|
| Code quality & bugs | `references/code-quality.md` | always |
| Tests | `references/tests.md` | test files or new logic changed |
| Error handling | `references/error-handling.md` | try/catch, fallbacks, error paths changed |
| Comments | `references/comments.md` | comments/docs added or modified |
| Type design | `references/type-design.md` | new/changed types |
| Simplification | `references/simplification.md` | after review passes, to polish |

## 3. Run reviewers

Spawn one general-purpose agent per selected aspect (parallel default; sequential if caller prefers). Each agent gets: review scope, plus instruction to **read its reference doc and follow it exactly**. Agents report findings; no code edits (except simplification, only when asked to apply).

Always fold this repo's `CLAUDE.md`/coding standards into every aspect — they override generic guidance.

## 4. Aggregate

Merge findings into one report, deduped, grouped by severity:

- **Critical** — must fix before merge (bugs, silent failures, standards violations)
- **Important** — should fix
- **Suggestions** — optional polish

Each item: `aspect — description [file:line] → fix`. Close with strengths and recommended action order. Nothing high-confidence surfaced → say so plainly.