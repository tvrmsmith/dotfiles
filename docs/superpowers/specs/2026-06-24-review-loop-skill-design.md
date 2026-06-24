# review-loop skill — design

**Date:** 2026-06-24
**Status:** Approved (design phase)

## Purpose

Run a review skill (default `pr-review-toolkit:review-pr`) in an iterative loop:
review → triage findings → ask user about ambiguous/unnecessary fixes → apply
approved fixes via subagent → re-review. Repeat until convergence or a max
iteration cap.

## Interface

User-level skill, stowed from `dot-claude/skills/review-loop/SKILL.md`. Invoked
as `/review-loop [natural-language args]`.

### Argument parsing (natural language)

The skill is markdown interpreted by the model, so arguments are free-form. The
model extracts up to three elements; all optional:

| Element | Default | Notes |
|---------|---------|-------|
| Max iterations | `4` | e.g. "max 6", "up to 3 loops" |
| Review command | `pr-review-toolkit:review-pr` | e.g. "use /security-review", "/code-review" |
| Focus / aspects | none | e.g. "focus on security and error handling" |

**Focus mapping:** for `pr-review-toolkit:review-pr`, focus maps to its native
`[review-aspects]` argument (`tests`, `errors`, `comments`, `types`, `code`,
`simplify`). For any other review command, focus is appended as plain review
guidance.

**Misparse safety net:** before the loop starts, echo the parsed config so a
misread is caught on turn 1:

```
Review: pr-review-toolkit:review-pr · Max: 4 · Focus: security, error handling · Target: git diff
```

Examples:
- `/review-loop` → defaults
- `/review-loop max 6, focus on security and tests`
- `/review-loop use /code-review up to 2 loops`

## Review command resolution

The loop always invokes the review command **explicitly by name**, so a command
marked `user-invocable-only` in `skillOverrides` still works — that override only
hides a skill from the auto-trigger listing; it remains invokable by exact name
(confirmed via skill-audit docs and the Skill-tool contract for user-typed
`/name` invocation).

Notes:
- Claude Code currently ignores `skillOverrides` for **plugin** sources
  (hardcoded `"on"`), so plugin review commands (e.g. `pr-review-toolkit:review-pr`,
  `code-review`) are always live regardless of override.
- Only a command set fully `off` or not installed cannot be invoked.

**Pre-flight check:** before entering the loop, confirm the named review command
resolves. If it does not (typo, disabled `off`, not installed), error on turn 1
echoing the parsed name — do not enter the loop. (Implementation: a live-fire
test that a user-invocable-only command actually invokes belongs in the test
phase, since running a real review has side effects.)

## Loop body (per iteration)

1. **Review** — run the review command in the main thread (no coordinator
   wrapper). The toolkit's analyzer agents already run as their own subagents,
   so file-reading is isolated; reports aggregate in the main thread, which is
   acceptable for the default 4 loops. Collect the aggregated findings list.

2. **Triage** — classify each finding:
   - **Clear** — high-value, unambiguous. Auto-approved for fixing.
   - **Ambiguous / unnecessary** — risky, low-value, or a judgment call.
     Surfaced to the user.

3. **Decision gate** — if any ambiguous/unnecessary findings exist this
   iteration, present them via `AskUserQuestion` (fix / skip; per-finding or
   grouped when several relate). Clear findings are NOT surfaced.

4. **Fix dispatch** — assemble approved findings (clear + user-approved
   ambiguous). Apply via subagent:
   - **Small set** → a single fix subagent handles the whole batch.
   - **Large set** → split findings into per-file / per-area batches, one
     subagent each, run in parallel where edits don't conflict.
   Deferred (skipped) findings are recorded, not fixed.

5. **Iteration summary** — one line, e.g.:
   `Iter 2/4: 5 findings · 3 fixed · 1 deferred · 1 skipped`

## Stop conditions

Loop ends when **any** holds:

- Max iterations reached.
- No actionable findings remain. This covers both:
  - a fully clean review (zero findings), and
  - the only findings left are ones the user already deferred/skipped (no
    progress possible).

## State across iterations

Track deferred/skipped findings between loops. Once the user skips a finding,
the loop does not re-surface it. Only genuinely new findings trigger the
decision gate on subsequent iterations.

## Final report

On exit, summarize:

- Total iterations run.
- Total findings fixed.
- Deferred/skipped list with the reason each was not fixed.
- Stop reason (max reached / no actionable findings).

## Out of scope (YAGNI)

- No coordinator-subagent wrapper around the review (marginal benefit at 4
  loops; main thread needs the findings for the decision gate anyway).
- No severity-threshold gate or "surface all findings" mode — only
  ambiguous/unnecessary findings are surfaced.
- No automatic commit/PR creation — the skill reviews and fixes only.
