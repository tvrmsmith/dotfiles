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

**Empirically verified (2026-06-24):** the Skill tool enforces `skillOverrides`
for *model invocation regardless of source* (plugin or user-level). A command
marked `user-invocable-only` / `off` / `name-only` cannot be invoked by the
running skill — it fails with:

```
Skill <name> is disabled for model invocation in skillOverrides settings
```

This holds for direct model invocation AND invocation from inside another
running skill (both tested, both blocked). Only a human typing `/name` invokes
such commands. So review-loop can directly invoke only review commands that are
*not* overridden (e.g. default `pr-review-toolkit:review-pr`, `code-review`,
`review`, `security-review`, `simplify` — none currently overridden).

**On invocation failure** (blocked by override, not installed, or typo),
review-loop does NOT silently fall back. It presents the failure to the user via
`AskUserQuestion` with three choices:

1. **Pick another review skill** — re-prompt for a different review command, then
   retry resolution.
2. **Read the `.md` inline** — locate the command's markdown file on disk, Read
   it, and execute its instructions inline (bypasses the Skill-tool gate). Only
   offered when the file can be located.
3. **Stop** — abort the loop.

The error message echoes the parsed command name so a typo is obvious.

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
