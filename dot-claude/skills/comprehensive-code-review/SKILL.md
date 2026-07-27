---
name: comprehensive-code-review
description: Use for a comprehensive, multi-aspect review of a diff, PR, or pre-commit changes — correctness, bugs, tests, error handling, comments, type design, spec conformance, and simplification.
---
# Comprehensive Code Review

Adversarial review of changed code across every applicable aspect below, then aggregate. Treat the diff as guilty until shown correct — dig for real defects, report only what survives scrutiny (no praise-seeking, no speculation padding).

## 1. Scope

Default target: unstaged + staged changes (`git diff` and `git diff --cached`). PR exists (`gh pr view`) → use its diff. Honor explicit scope caller gives.

## 2. Pick applicable aspects

Caller named specific aspects (e.g. "review error handling and tests") → run only those. Else select from changed files what applies:

| Aspect | Reference / owner | Required skills | Apply when |
|--------|-------------------|-----------------|------------|
| Code quality & bugs | `references/code-quality.md` | `coding-standards` | always |
| Tests | `references/tests.md` | `wshp:test-best-practices` | test files or new logic changed |
| Error handling | `references/error-handling.md` | — | try/catch, fallbacks, error paths changed |
| Comments | `references/comments.md` | — | comments/docs added or modified |
| Type design | `references/type-design.md` | `coding-standards` | new/changed types |
| Spec conformance & standards | `mattpocock-skills:code-review` | — | always (see step 3) |
| Simplification | `references/simplification.md` | `coding-standards` | → step 4 |

**Required skills** are per-aspect, not global — `coding-standards` covers domain/DTO design and React, so it belongs to the aspects that judge code shape, not to comments or error handling. Each aspect agent loads only its own row.

## 3. Run reviews

Two tracks. Do **3a first** — it is one tool call, and the item that trails a multi-agent batch is the item that gets dropped. Both tracks then run concurrently.

### 3a. Delegated track (Matt Pocock)

Invoke `mattpocock-skills:code-review` from the main thread and let it run — it spawns its own sub-agents; don't wrap it in another agent. It returns a Spec axis and a Standards axis; take both to step 5.

### 3b. In-house aspects

Spawn one general-purpose agent per selected aspect (simplification runs in step 4). Give each agent this exact prompt, substituting only `{ASPECT}`, `{SCOPE}`, `{ASPECT_FILE}`, and `{REQUIRED_SKILLS}` — copy the rest verbatim so every reviewer runs on the same brief. `{ASPECT_FILE}` is the aspect's reference doc from the step-2 table, resolved to an **absolute** path (spawned agents run in the target repo, where a relative `references/…` won't resolve). `{REQUIRED_SKILLS}` is that aspect's Required skills cell, comma-separated; when the cell is `—`, drop line 1 and renumber:

```
Adversarially review this change for {ASPECT} — treat the diff as guilty until shown correct.

Scope: {SCOPE}
1. Invoke these skills before you start reviewing and follow them — they override generic guidance: {REQUIRED_SKILLS}.
2. Read {ASPECT_FILE} and follow it exactly, including any further skills it tells you to load.
Report findings only — no code edits. Report only what survives scrutiny — no speculation padding.
Label every finding by severity and use this exact format:
  `severity — description [file:line] → concrete fix`
Severity: Critical (must fix before merge — bugs, silent failures, standards violations) · Important (real issue, not a blocker) · Suggestion (optional polish).
```

Step 3 is done when every spawned aspect agent has returned findings **and** `mattpocock-skills:code-review` has returned both its Spec and Standards axes. The aspect agents returning is not step 3 finishing.

## 4. Simplify

After step 3 returns, run simplification (`references/simplification.md`) — never in the parallel batch, since it must see the reviewed code settled. Advisory by default; apply edits only when the caller asks.

## 5. Aggregate

Merge in-house findings and Matt's **Standards** axis into one report, deduped, grouped by the severity labels above. Present Matt's **Spec** axis as its own section, un-merged. That section is never absent: if the delegated track didn't run, the section says so instead of being omitted, so a skipped Spec axis can't be mistaken for a clean one. Every aspect selected in step 2 appears in the report — state "no findings" explicitly where an aspect ran clean. Close with strengths and recommended action order.
