---
name: review-loop
description: Iteratively review and fix code in a loop until it converges or hits a max-iteration cap. Triggers on "review loop", "loop the review".
---
# Review Loop

Iteratively review and fix code: run review skill, triage findings, ask user only about ambiguous or unnecessary fixes, apply approved fixes in subagent, then re-review. Repeat until review converges or hits max-iteration cap.

## 1. Parse arguments

Arguments free-form natural language. Extract up to three optional elements; fall back to defaults when element absent:

| Element | Default | Examples |
|---------|---------|----------|
| Max iterations | `4` | "max 6", "up to 3 loops", "3x" |
| Review command | `comprehensive-code-review` | "use /code-review", "/security-review" |
| Focus / aspects | none | "focus on security and error handling", "tests only" |

**Focus mapping:** if review command is `comprehensive-code-review`, pass focus as the aspects it names in natural language (code quality & bugs, tests, error handling, comments, type design, spec conformance, simplification). Focus with no matching aspect (e.g. "security") rides along as plain guidance rather than being dropped. For any other review command, append focus as plain review guidance.

After parsing, echo resolved config in one line before anything else, so misparse caught immediately:

```
Review: <command> · Max: <n> · Focus: <focus or "none"> · Target: git diff
```

## 2. Review command failure gate

No pre-flight probe — review command invoked for real inside loop (step 3a, via subagent), and invocation problem only surfaces there. This section defines what to do when invocation fails; step 3a refers back to it.

Command marked `user-invocable-only` in `skillOverrides` **cannot be invoked by the model** (subagent runs as model) — fails with:

```
Skill <name> is disabled for model invocation in skillOverrides settings
```

If invoking review command fails (override-blocked, not installed, or typo), do NOT silently continue. Present failure to user with `AskUserQuestion`, echo parsed command name, offer three choices:

1. **Pick another review skill** — ask for different review command, then retry invocation at 3a with new command.
2. **Read the `.md` inline** — locate command's markdown file on disk (search
   `~/.claude/plugins/cache/**/commands/<name>.md`, `~/.claude/plugins/cache/**/skills/<name>/SKILL.md`,
   `~/.claude/plugins/marketplaces/**/commands/<name>.md`, `~/.claude/plugins/marketplaces/**/skills/<name>/SKILL.md`,
   and `~/.claude/skills/<name>/SKILL.md`), Read it, have subagent follow those instructions inline instead of invoking skill. Only offer when file actually located.
3. **Stop** — abort loop, report why.

## 3. The loop

Repeat each iteration until stop condition (section 4) holds. Track iteration number against max.

### 3a. Review (in a subagent)

Dispatch coordinator subagent (general-purpose) that:
- Runs resolved review command on current changes (git diff by default), applying parsed focus.
- Returns ONLY condensed findings list — one line per finding:
  `path:line · severity · problem · suggested fix`. No verbose analyzer reports.

Keeps analyzer output and aggregation out of main thread across iterations. If subagent reports invocation failure, run failure gate from section 2.

### 3b. Triage

Classify each returned finding:
- **Clear** — high-value, unambiguous. Auto-approved for fixing; not surfaced.
- **Ambiguous / unnecessary** — risky, low-value, or judgment call. Must surface to user.

Do not re-classify or re-surface findings user already deferred in previous iteration (see section 4 state).

### 3c. Decision gate

If any ambiguous/unnecessary findings this iteration, present with `AskUserQuestion` (group related findings, split into multiple sequential questions if exceed one question's capacity; each option is fix or skip). Clear findings NOT shown. Approved set = clear findings + ambiguous findings user chose to fix. Findings user chose not to fix recorded as deferred. If every finding this iteration clear, skip question entirely, go straight to fix dispatch (3d).

### 3d. Fix dispatch

Apply approved findings via subagent(s):
- **Small set** → single fix subagent receives whole batch, applies edits, reports what changed.
- **Large set** → split findings into per-file / per-area batches and dispatch one subagent per batch, in parallel only where edits cannot conflict (never two subagents editing same file at once).

Deferred findings NOT fixed. Do not commit automatically — leave changes in working tree for next iteration's review to verify.

### 3e. Iteration summary

After fixes, print one line:

```
Iter <i>/<max>: <total> findings · <fixed> fixed · <deferred> deferred
```

Then evaluate stop conditions (section 4). If none hold, start next iteration at 3a.

## 4. Stop conditions and state

Stop loop when ANY holds:
- Iteration count reaches max iterations.
- No actionable findings remain. Evaluate this AFTER removing running deferred set from this iteration's findings, since 3a subagent re-runs full review with no knowledge of deferred findings and will re-report them every iteration. Stop when no NEW clear/ambiguous findings remain — i.e. review came back clean (zero findings), OR only findings left are ones user already deferred (no progress possible).

**State across iterations:** maintain running set of deferred findings. Once user defers finding, never surface again in this run; only genuinely new findings trigger decision gate on later iterations.

## 5. Final report

On exit, print:
- Total iterations run.
- Total findings fixed.
- Deferred list, each with reason not fixed.
- Stop reason (max reached / no actionable findings / user aborted at failure gate).