---
name: comprehensive-code-review
description: Reviews a diff, PR, or pre-commit changes for code quality, bugs, tests, error handling, comments, type design, and simplification.
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
| Simplification | `references/simplification.md` | phase 2 — runs in step 3b |

## 2b. Delegate spec conformance & Fowler standards

For **spec conformance** (does the diff implement the originating issue/PRD? missing requirements, scope creep, wrong implementation) and a **Fowler smell baseline** standards pass, invoke the `mattpocock-skills:code-review` skill — it owns those axes and tracks upstream, so don't duplicate them here. Present its `## Standards` / `## Spec` output as its own section, kept separate from the severity buckets below (its two axes are deliberately un-merged).

## 3. Run reviewers

Spawn one general-purpose agent per selected aspect (parallel default; sequential if caller prefers). Simplification is excluded here — it runs in step 3b. Each agent gets:

- the review scope,
- instruction to load the `coding-standards` skill and this repo's `CLAUDE.md` (they override generic guidance),
- instruction to **read its reference doc and follow it exactly**,
- the shared severity labels and finding format below.

Agents report findings only — no code edits.

**Severity** — every finding carries one:

- **Critical** — must fix before merge: bugs, silent failures, standards violations.
- **Important** — real issue to fix, not a blocker.
- **Suggestion** — optional polish.

**Finding format:** `severity — description [file:line] → concrete fix`.

## 3b. Simplify

After the step-3 aspects return, run simplification (`references/simplification.md`) — never in the parallel batch, since it must see the reviewed code settled. Advisory by default; apply edits only when the caller asks.

## 4. Aggregate

Merge findings into one report, deduped, grouped by the severity labels above. Every aspect selected in step 2 appears in the report — state "no findings" explicitly where an aspect ran clean. Close with strengths and recommended action order.