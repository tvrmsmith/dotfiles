---
name: review-loop
description: Iteratively review and fix code in a loop until it converges or hits a max-iteration cap. Triggers on "review loop", "loop the review".
---
# Review Loop

## 1. Parse arguments

Arguments free-form natural language. Extract up to three optional elements; fall back to defaults when element absent:

| Element | Default | Examples |
|---------|---------|----------|
| Max iterations | `4` | "max 6", "up to 3 loops", "3x" |
| Review command | `comprehensive-code-review` | "use /code-review", "/security-review" |
| Focus / aspects | none | "focus on security and error handling", "tests only" |
| Model preset | none (recommend + confirm each iteration) | "model=sonnet", "use opus", "haiku for fixes" |

**Focus mapping:** if review command is `comprehensive-code-review`, pass focus as the aspects it names in natural language (code quality & bugs, tests, error handling, comments, type design, spec conformance, simplification). Focus with no matching aspect (e.g. "security") rides along as plain guidance rather than being dropped. For any other review command, append focus as plain review guidance.

After parsing, echo resolved config in one line before anything else, so misparse caught immediately:

```
Review: <command> · Max: <n> · Focus: <focus or "none"> · Model: <preset or "per-iteration"> · Target: git diff
```

## 2. Review command failure gate

No pre-flight probe — the review command runs for real inside the loop (step 3a, via subagent), so an invocation problem only surfaces there.

Command marked `user-invocable-only` in `skillOverrides` **cannot be invoked by the model** (subagent runs as model) — fails with:

```
Skill <name> is disabled for model invocation in skillOverrides settings
```

If invoking the review command fails (override-blocked, not installed, or typo), surface it: present the failure to the user with `AskUserQuestion`, echo the parsed command name, offer three choices:

1. **Pick another review skill** — ask for different review command, then retry invocation at 3a with new command.
2. **Read the `.md` inline** — locate command's markdown file on disk (search
   `~/.claude/plugins/cache/**/commands/<name>.md`, `~/.claude/plugins/cache/**/skills/<name>/SKILL.md`,
   `~/.claude/plugins/marketplaces/**/commands/<name>.md`, `~/.claude/plugins/marketplaces/**/skills/<name>/SKILL.md`,
   and `~/.claude/skills/<name>/SKILL.md`), Read it, have subagent follow those instructions inline instead of invoking skill. Only offer when file actually located.
3. **Stop** — abort loop, report why.

## 3. The loop

Repeat each iteration until stop condition (section 4) holds.

### 3a. Review (in a subagent)

Dispatch coordinator subagent (general-purpose) that:
- Runs resolved review command on current changes (git diff by default), applying parsed focus.
- Returns ONLY a condensed findings list — one line per finding:
  `path:line · severity · problem · suggested fix`.

Keeps analyzer output and aggregation out of main thread across iterations. If subagent reports invocation failure, run failure gate from section 2.

### 3b. Triage

Carry deferred findings forward untouched (see section 4 state); classify only the rest:
- **Clear** — high-value, unambiguous. Auto-approved for fixing; not surfaced.
- **Ambiguous / unnecessary** — risky, low-value, or judgment call. Surface to user.

### 3c. Decision gate

If any ambiguous/unnecessary findings this iteration, present with `AskUserQuestion` (group related findings, split into multiple sequential questions if they exceed one question's capacity; each option is fix or skip). Approved set = clear findings + ambiguous findings the user chose to fix. Findings the user chose not to fix are recorded as deferred. If every finding this iteration is clear, skip the question, go straight to fix dispatch (3d).

### 3d. Model selection

Pick the model that will apply this iteration's approved fixes. Routing policy:

- Default **Sonnet** (`sonnet`). Escalate to **Opus** (`opus`) for subtle logic, cross-file refactors, or correctness/security judgment. **Haiku** (`haiku`) only for purely mechanical fixes (renames, typos, formatting) — sparingly. Never **Fable**.

If a model preset was parsed (step 1), use it and skip the prompt. Otherwise present the recommendation with `AskUserQuestion`: recommended model first, labelled `(Recommended)`, then the other allowed models so the choice can be overridden. **Ask every iteration** — each iteration's fixes differ and may warrant a different model. When a large batch is split across parallel subagents (3e) whose complexity differs materially, recommend per-batch rather than one model for the whole iteration.

### 3e. Fix dispatch

Apply approved findings via subagent(s), dispatched with the selected model via the Agent tool's `model` parameter:
- **Small set** → single fix subagent receives whole batch, applies edits, reports what changed.
- **Large set** → split findings into per-file / per-area batches and dispatch one subagent per batch, in parallel only where edits cannot conflict (never two subagents editing same file at once).

Leave changes in the working tree for the next iteration's review to verify.

### 3f. Iteration summary

After fixes, print one line:

```
Iter <i>/<max>: <total> findings · <fixed> fixed · <deferred> deferred
```

Then evaluate stop conditions (section 4). If none hold, start next iteration at 3a.

## 4. Stop conditions and state

Stop loop when ANY holds:
- Iteration count reaches max iterations.
- No actionable findings remain (see State below) — the review converges (comes back clean, zero findings), OR the only findings left are ones the user already deferred (no progress possible).

**State across iterations:** maintain a running set of deferred findings. The 3a subagent re-runs the full review with no knowledge of what was deferred, so it re-reports deferred findings every iteration — subtract them before triage and before the stop check. Once the user defers a finding, never surface it again this run; only genuinely new findings reach the decision gate.

**Finding identity:** match a finding to the deferred set by `path` + normalized problem text, never by line number — line numbers drift as fixes apply above them, so a line-keyed match would re-surface a moved deferred finding or falsely swallow a new one as already-deferred.

## 5. Final report

On exit, print:
- Total iterations run.
- Total findings fixed.
- Deferred list, each with reason not fixed.
- Stop reason (max reached / no actionable findings / user aborted at failure gate).