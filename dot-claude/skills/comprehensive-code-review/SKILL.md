---
name: comprehensive-code-review
description: Use for a comprehensive, multi-aspect review of a diff, PR, or pre-commit changes — correctness, bugs, tests, error handling, comments, type design, spec conformance, and simplification.
---
# Comprehensive Code Review

Review changed code across every applicable aspect below, then aggregate.

## 1. Scope

Default target: unstaged + staged changes (`git diff` and `git diff --cached`). PR exists (`gh pr view`) → use its diff. Honor explicit scope caller gives.

## 2. Pick applicable aspects

Caller named specific aspects (e.g. "review error handling and tests") → run only those. Else select from changed files what applies:

| Aspect | Reference / owner | Apply when |
|--------|-------------------|------------|
| Code quality & bugs | `references/code-quality.md` | always |
| Tests | `references/tests.md` | test files or new logic changed |
| Error handling | `references/error-handling.md` | try/catch, fallbacks, error paths changed |
| Comments | `references/comments.md` | comments/docs added or modified |
| Type design | `references/type-design.md` | new/changed types |
| Spec conformance & standards | `mattpocock-skills:code-review` | always (see step 3) |
| Simplification | `references/simplification.md` | runs last, in step 4 (must see settled code) |

## 3. Run reviews

Two tracks, launched together (parallel default; sequential if caller prefers).

**In-house aspects** — spawn one general-purpose agent per selected aspect (simplification excluded — it runs in step 4). Each agent gets:

- the review scope,
- instruction to load the `coding-standards` skill and this repo's `CLAUDE.md` (they override generic guidance),
- instruction to **read its reference doc and follow it exactly**,
- the shared severity labels and finding format below.

Agents report findings only — no code edits.

**Delegated (Matt Pocock)** — invoke the `mattpocock-skills:code-review` skill from the main thread (it spawns its own Standards + Spec sub-agents; don't wrap it in another agent). It tracks upstream, so its axes stay current without edits here. Consume:

- its **Spec** axis — does the diff implement the originating issue/PRD? missing requirements, scope creep, wrong implementation. This is the axis the in-house aspects don't cover.
- its **Standards** axis (repo standards + Fowler smell baseline) — a deliberate cross-check on the in-house standards pass (`coding-standards` skill + `code-quality.md`), not the sole owner. Fold matching findings together.

**Severity** — every finding carries one:

- **Critical** — must fix before merge: bugs, silent failures, standards violations.
- **Important** — real issue to fix, not a blocker.
- **Suggestion** — optional polish.

**Finding format:** `severity — description [file:line] → concrete fix`.

## 4. Simplify

After step 3 returns, run simplification (`references/simplification.md`) — never in the parallel batch, since it must see the reviewed code settled. Advisory by default; apply edits only when the caller asks.

## 5. Aggregate

Merge in-house findings into one report, deduped, grouped by the severity labels above. Present Matt's **Spec** axis as its own section, un-merged (it's a different kind of finding — intent, not code quality). Every aspect selected in step 2 appears in the report — state "no findings" explicitly where an aspect ran clean. Close with strengths and recommended action order.
