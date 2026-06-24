# review-loop Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a user-level Claude Code skill that runs a review skill (default `pr-review-toolkit:review-pr`) in an iterative loop — review in a subagent, triage findings, gate ambiguous fixes on the user, apply approved fixes via subagent, repeat until convergence or a max-iteration cap.

**Architecture:** The artifact is a single markdown instruction file, `dot-claude/skills/review-loop/SKILL.md`, interpreted by the model at invocation. There is no executable code: every behavior (argument parsing, loop control, subagent dispatch, user gates) is expressed as instructions the agent follows. The repo is GNU Stow-managed; `dot-claude/skills/` is symlinked into `~/.claude/skills/`, so the file is live once written. The model only sees newly added skills after a skills reload (`/reload-skills`) or new session.

**Tech Stack:** Markdown + YAML frontmatter. No build, no deps. Verification is structural (grep for required sections) plus a live invocation smoke-test after reload.

## Global Constraints

- Skill path: `dot-claude/skills/review-loop/SKILL.md` (stowed to `~/.claude/skills/review-loop/SKILL.md`).
- Frontmatter required: `name: review-loop` and a `description:` (skill won't list correctly without it).
- Default review command: `pr-review-toolkit:review-pr`. Default max iterations: `4`.
- Argument style: natural language, parsed by the model (max iterations, review command, focus/aspects). Echo parsed config before looping.
- Review runs in a **coordinator subagent** that returns only a condensed findings list.
- Decision gate, triage, fix dispatch run in the **main thread** (subagents cannot prompt the user).
- Only **ambiguous/unnecessary** findings are surfaced to the user; clear findings are auto-approved.
- A `user-invocable-only` review command cannot be invoked by the model (verified) — on invocation failure, ask the user: pick another review skill / read `.md` inline / stop.
- Stop when: max iterations reached OR no actionable findings remain (clean review, or only deferred/skipped left).
- Skipped findings are not re-surfaced in later iterations.
- Caveman style is the user's global default but does NOT apply inside the authored skill file — write the skill in normal, clear prose.
- Reference spec: `docs/superpowers/specs/2026-06-24-review-loop-skill-design.md`.

---

## File Structure

- `dot-claude/skills/review-loop/SKILL.md` — the entire skill. One file, one responsibility (orchestrate the review loop). No supporting scripts needed.
- `CLAUDE.md` (repo root) — one-line note pointing at the new skill, only if a skills index pattern exists (check first; do not invent one).

The skill file is built incrementally across Tasks 1–5 (each appends one section), then installed and smoke-tested in Task 6. Tasks are ordered so the file is always syntactically valid markdown after each commit.

---

### Task 1: Scaffold skill + frontmatter, overview, argument parsing

**Files:**
- Create: `dot-claude/skills/review-loop/SKILL.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the skill file with frontmatter (`name: review-loop`), an Overview section, and an "Argument parsing" section that the later sections build on. Establishes the parsed-config vocabulary: `max iterations`, `review command`, `focus`.

- [ ] **Step 1: Create the file with frontmatter, overview, and argument parsing**

Write `dot-claude/skills/review-loop/SKILL.md` with exactly this content:

````markdown
---
name: review-loop
description: Run a review skill (default pr-review-toolkit:review-pr) in an iterative loop — review, gate ambiguous fixes on the user, apply approved fixes via subagent, repeat to convergence or a max-iteration cap. Triggers on "review loop", "loop the review", "/review-loop".
---

# Review Loop

Iteratively review and fix code: run a review skill, triage its findings, ask the
user only about ambiguous or unnecessary fixes, apply the approved fixes in a
subagent, then re-review. Repeat until the review converges or a max-iteration
cap is hit.

## 1. Parse arguments

Arguments are free-form natural language. Extract up to three optional elements;
fall back to defaults when an element is absent:

| Element | Default | Examples |
|---------|---------|----------|
| Max iterations | `4` | "max 6", "up to 3 loops", "3x" |
| Review command | `pr-review-toolkit:review-pr` | "use /code-review", "/security-review" |
| Focus / aspects | none | "focus on security and error handling", "tests only" |

**Focus mapping:** if the review command is `pr-review-toolkit:review-pr`, map
focus to its native `[review-aspects]` argument (`tests`, `errors`, `comments`,
`types`, `code`, `simplify`). For any other review command, append focus as plain
review guidance.

After parsing, echo the resolved config in one line before doing anything else,
so a misparse is caught immediately:

```
Review: <command> · Max: <n> · Focus: <focus or "none"> · Target: git diff
```
````

- [ ] **Step 2: Verify frontmatter and required sections exist**

Run: `rg -n '^name: review-loop$|^description:|^## 1\. Parse arguments$' dot-claude/skills/review-loop/SKILL.md`
Expected: three matches (name, description, the section heading).

- [ ] **Step 3: Commit**

```bash
git add dot-claude/skills/review-loop/SKILL.md
git commit -m "feat(review-loop): scaffold skill with arg parsing"
```

---

### Task 2: Review-command resolution + failure gate

**Files:**
- Modify: `dot-claude/skills/review-loop/SKILL.md` (append section 2)

**Interfaces:**
- Consumes: parsed `review command` from Task 1.
- Produces: the resolution + failure-handling behavior referenced by the loop's review step in Task 3.

- [ ] **Step 1: Append the Review command failure gate section**

Append to `dot-claude/skills/review-loop/SKILL.md`:

````markdown
## 2. Review command failure gate

There is no pre-flight probe — the review command is invoked for real inside the
loop (step 3a, via a subagent), and an invocation problem only surfaces there.
This section defines what to do when that invocation fails; step 3a refers back
to it.

A command marked
`user-invocable-only` in `skillOverrides` **cannot be invoked by the model** (the
subagent runs as the model) — it fails with:

```
Skill <name> is disabled for model invocation in skillOverrides settings
```

If invoking the review command fails (override-blocked, not installed, or a
typo), do NOT silently continue. Present the failure to the user with
`AskUserQuestion`, echoing the parsed command name, and offer three choices:

1. **Pick another review skill** — ask for a different review command, then retry
   resolution from the top of this section.
2. **Read the `.md` inline** — locate the command's markdown file on disk (search
   `~/.claude/plugins/cache/**/commands/<name>.md`, `~/.claude/plugins/cache/**/skills/<name>/SKILL.md`,
   and `~/.claude/skills/<name>/SKILL.md`), Read it, and have the subagent follow
   those instructions inline instead of invoking the skill. Only offer this when
   the file is actually located.
3. **Stop** — abort the loop and report why.
````

- [ ] **Step 2: Verify the section and the verbatim error string are present**

Run: `rg -n '## 2\. Review command failure gate|disabled for model invocation|Pick another review skill' dot-claude/skills/review-loop/SKILL.md`
Expected: three matches.

- [ ] **Step 3: Commit**

```bash
git add dot-claude/skills/review-loop/SKILL.md
git commit -m "feat(review-loop): add command resolution + failure gate"
```

---

### Task 3: Loop body — review subagent, triage, decision gate

**Files:**
- Modify: `dot-claude/skills/review-loop/SKILL.md` (append section 3, parts a–c)

**Interfaces:**
- Consumes: resolved review command (Task 2), parsed config (Task 1).
- Produces: the findings list shape (`path:line · severity · problem · suggested fix`), the clear-vs-ambiguous classification, and the approved-findings set consumed by Task 4's fix dispatch.

- [ ] **Step 1: Append the loop intro + review + triage + decision-gate sub-sections**

Append to `dot-claude/skills/review-loop/SKILL.md`:

````markdown
## 3. The loop

Repeat the following each iteration until a stop condition (section 4) holds.
Track the iteration number against the max.

### 3a. Review (in a subagent)

Dispatch a coordinator subagent (general-purpose) that:
- Runs the resolved review command on the current changes (git diff by default),
  applying the parsed focus.
- Returns ONLY a condensed findings list — one line per finding:
  `path:line · severity · problem · suggested fix`. No verbose analyzer reports.

This keeps the analyzer output and aggregation out of the main thread across
iterations. If the subagent reports an invocation failure, run the failure gate
from section 2.

### 3b. Triage

Classify each returned finding:
- **Clear** — high-value and unambiguous. Auto-approved for fixing; not surfaced.
- **Ambiguous / unnecessary** — risky, low-value, or a judgment call. Must be
  surfaced to the user.

Do not re-classify or re-surface findings the user already skipped in a previous
iteration (see section 4 state).

### 3c. Decision gate

If there are any ambiguous/unnecessary findings this iteration, present them with
`AskUserQuestion` (one question; group related findings; each option is fix or
skip). Clear findings are NOT shown. The approved set = clear findings + any
ambiguous findings the user chose to fix. Skipped findings are recorded as
deferred.
````

- [ ] **Step 2: Verify sub-sections present**

Run: `rg -n '### 3a\. Review|### 3b\. Triage|### 3c\. Decision gate' dot-claude/skills/review-loop/SKILL.md`
Expected: three matches.

- [ ] **Step 3: Commit**

```bash
git add dot-claude/skills/review-loop/SKILL.md
git commit -m "feat(review-loop): add review subagent, triage, decision gate"
```

---

### Task 4: Loop body — fix dispatch + iteration summary

**Files:**
- Modify: `dot-claude/skills/review-loop/SKILL.md` (append section 3, parts d–e)

**Interfaces:**
- Consumes: the approved-findings set and deferred set from Task 3.
- Produces: applied fixes in the working tree; a one-line iteration summary.

- [ ] **Step 1: Append fix-dispatch and summary sub-sections**

Append to `dot-claude/skills/review-loop/SKILL.md`:

````markdown
### 3d. Fix dispatch

Apply the approved findings via subagent(s):
- **Small set** → a single fix subagent receives the whole batch, applies the
  edits, and reports what it changed.
- **Large set** → split findings into per-file / per-area batches and dispatch
  one subagent per batch, in parallel only where their edits cannot conflict
  (never two subagents editing the same file at once).

Deferred (skipped) findings are NOT fixed. Do not commit automatically — leave
changes in the working tree for the next iteration's review to verify.

### 3e. Iteration summary

After fixes, print one line:

```
Iter <i>/<max>: <total> findings · <fixed> fixed · <deferred> deferred · <skipped> skipped
```

Then evaluate stop conditions (section 4). If none hold, start the next
iteration at 3a.
````

- [ ] **Step 2: Verify sub-sections present**

Run: `rg -n '### 3d\. Fix dispatch|### 3e\. Iteration summary' dot-claude/skills/review-loop/SKILL.md`
Expected: two matches.

- [ ] **Step 3: Commit**

```bash
git add dot-claude/skills/review-loop/SKILL.md
git commit -m "feat(review-loop): add fix dispatch and iteration summary"
```

---

### Task 5: Stop conditions, cross-iteration state, final report

**Files:**
- Modify: `dot-claude/skills/review-loop/SKILL.md` (append sections 4–5)

**Interfaces:**
- Consumes: deferred/skipped set and iteration counter from Tasks 3–4.
- Produces: loop termination behavior and the final summary. Completes the skill.

- [ ] **Step 1: Append stop-conditions, state, and final-report sections**

Append to `dot-claude/skills/review-loop/SKILL.md`:

````markdown
## 4. Stop conditions and state

Stop the loop when ANY holds:
- The iteration count reaches max iterations.
- No actionable findings remain — i.e. the review came back clean (zero
  findings), OR the only findings left are ones the user already deferred/skipped
  (no progress is possible).

**State across iterations:** maintain a running set of skipped findings. Once the
user skips a finding, never surface it again in this run; only genuinely new
findings trigger the decision gate on later iterations.

## 5. Final report

On exit, print:
- Total iterations run.
- Total findings fixed.
- The deferred/skipped list, each with the reason it was not fixed.
- The stop reason (max reached / no actionable findings).
````

- [ ] **Step 2: Verify final sections present**

Run: `rg -n '## 4\. Stop conditions and state|## 5\. Final report' dot-claude/skills/review-loop/SKILL.md`
Expected: two matches.

- [ ] **Step 3: Commit**

```bash
git add dot-claude/skills/review-loop/SKILL.md
git commit -m "feat(review-loop): add stop conditions, state, final report"
```

---

### Task 6: Install, reload, and live smoke-test

**Files:**
- Modify: none (install via stow), optional `CLAUDE.md` note.

**Interfaces:**
- Consumes: the complete skill file.
- Produces: a stowed, loadable, invocation-verified skill.

- [ ] **Step 1: Confirm the symlink is already in place (stow)**

Run: `ls -l ~/.claude/skills/review-loop/SKILL.md`
Expected: a path that resolves into `dot-claude/skills/review-loop/SKILL.md`.
If it does NOT exist, run: `cd ~/dev/personal/dotfiles && stow --dotfiles -t "$HOME" .` and re-check.

- [ ] **Step 2: Reload skills**

In the Claude session, run `/reload-skills`.
Expected: `review-loop` appears in the available-skills listing.

- [ ] **Step 3: Smoke-test argument parsing (dry)**

Invoke `/review-loop` against a working tree that has a small diff. Confirm the
skill, on turn 1, echoes:
```
Review: pr-review-toolkit:review-pr · Max: 4 · Focus: none · Target: git diff
```
and then proceeds to dispatch the review subagent (or, on a clean tree, stops at
section 4 with "no actionable findings"). Then invoke
`/review-loop max 2, focus on security` and confirm the echo reflects
`Max: 2 · Focus: security`.

- [ ] **Step 4: Add CLAUDE.md note only if an index pattern exists**

Check repo-root `CLAUDE.md` for an existing "skills" index/list. If one exists,
add a one-line pointer to `review-loop`. If no such pattern exists, skip — do not
invent one.

- [ ] **Step 5: Commit any changes**

```bash
git add -A
git commit -m "chore(review-loop): install and document skill"
```
(If no files changed in steps 1–4, skip the commit.)

---

## Self-Review

**Spec coverage:**
- Argument parsing (max / command / focus) + echo → Task 1. ✓
- Focus → review-aspects mapping → Task 1. ✓
- Command resolution + user-invocable-only failure gate (pick another / inline / stop) → Task 2. ✓
- Review in coordinator subagent returning condensed findings → Task 3a. ✓
- Triage clear vs ambiguous → Task 3b. ✓
- Decision gate surfaces only ambiguous → Task 3c. ✓
- Adaptive fix dispatch (single vs batched subagents) → Task 3d. ✓
- Iteration summary line → Task 3e. ✓
- Stop conditions (max / no actionable) → Task 4. ✓
- Skipped-findings state not re-surfaced → Task 4. ✓
- Final report → Task 5. ✓
- Install/load → Task 6. ✓

**Placeholder scan:** No TBD/TODO; each task contains the exact markdown to write. Verification steps use concrete `rg` commands with expected match counts.

**Type consistency:** Section numbering (1–5) and sub-section labels (3a–3e) are referenced consistently across tasks; the findings-line format `path:line · severity · problem · suggested fix` is used identically in 3a and consumed in 3b–3d. The verbatim override error string matches the spec and the memory note.

**Note on TDD:** The deliverable is prose, not code, so there are no unit tests. Verification is structural (`rg` per task) plus the live smoke-test in Task 6. This is the appropriate test cycle for a markdown skill.
