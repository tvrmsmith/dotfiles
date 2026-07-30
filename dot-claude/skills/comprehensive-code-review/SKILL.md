---
name: comprehensive-code-review
description: Use for a comprehensive, multi-aspect review of a diff, PR, or pre-commit changes — correctness, bugs, tests, error handling, comments, React, type design, spec conformance, and simplification.
---
# Comprehensive Code Review

Adversarial review of changed code across every applicable aspect below, then aggregate. Treat diff as guilty until shown correct — dig for real defects, report only what survives scrutiny (no praise-seeking, no speculation padding).

## 1. Scope

Default target: unstaged + staged changes (`git diff` and `git diff --cached`). PR exists (`gh pr view`) → use its diff. Honor explicit scope caller gives.

Neither `git diff` form shows untracked files, so pre-commit review skip brand-new files entirely. Run `git add -N` on anything untracked first, so it land in diff — then `git reset -- <those paths>` once step 4 done, since those intent-to-add entries otherwise linger in caller's index and change how later `git stash` or `git commit` behave.

Resolve scope once, into literal diff command(s) both tracks use — every downstream agent gets those commands verbatim, never prose label like "current changes".

## 2. Pick applicable aspects

Caller named specific aspects (e.g. "review error handling and tests") → run only those. Else select from changed files what applies:

| Aspect | Reference / owner | Required skills | Apply when |
|--------|-------------------|-----------------|------------|
| Correctness & bugs | `references/code-quality.md`, `references/error-handling.md`, `references/comments.md` | — | always |
| Tests | `references/tests.md` | — | test files or new logic changed |
| React | — | `coding-standards` | React components or hooks changed — `.jsx`/`.tsx`, or JSX / `use*` in `.js`/`.ts` |
| Simplification | `references/simplification.md` | — | always — advisory, unless caller asks for edits |
| Spec conformance & standards | `mattpocock-skills:code-review` | — | always — runs as 3a, **never** as 3b spawn |

Type design has no in-house aspect — Matt's Standards axis cover it.

Simplification batches with rest in advisory mode, since nothing mutates between steps 3 and 4. Caller asked for edits applied → pull it out of batch, run after step 4 instead, so it edit settled code.

## 3. Run reviews

Two tracks. Work 3a's setup **first** — item trailing multi-agent batch is item that gets dropped. Then spawn Matt's two sub-agents and every 3b aspect agent in **one batched message**, so all run concurrently.

### 3a. Delegated track (Matt Pocock)

Invoke `mattpocock-skills:code-review` from main thread — it loads instructions you then execute yourself; don't wrap in another agent. Its steps 1–3 are setup you do inline; its step 4 spawns Standards and Spec sub-agents — batch those with 3b's. **Stop after its step 4**: this skill's step 4 replaces its step 5, whose "do not merge or rerank" rule applies only to its own standalone report. Take its two raw axes there.

**Pre-resolve everything it would otherwise stop and ask for.** Each of these blocks unattended run:

- **Diff command** — its step 1 builds `git diff <fixed-point>...HEAD`, which reads committed history only and **cannot see working tree**. Default scope is uncommitted, so `HEAD...HEAD` empty and it aborts on empty diff. Override it: hand its sub-agents diff command(s) resolved in step 1 above, so both tracks review same change set. Committed scope (PR, branch vs base) → its three-dot form already right; pass that.
- **Spec source** — originating issue/PRD: bead, JIRA key, or spec file. Its step 2 asks when it can't find one. No spec exists → say so explicitly, so it skips Spec sub-agent by design rather than by blocking.
- **Issue tracker** — its preamble tells agent to run `/setup-matt-pocock-skills` when `docs/agents/issue-tracker.md` missing, which most repos don't have. State up front none configured and it should proceed without one.

### 3b. In-house aspects

Spawn one general-purpose agent per selected in-house aspect — Spec conformance row is 3a's, never spawned here. Give each agent this exact prompt, substituting only `{ASPECT}`, `{SCOPE}`, `{ASPECT_FILES}`, and `{REQUIRED_SKILLS}` — copy rest verbatim so every reviewer runs on same brief.

- `{SCOPE}` — literal diff command(s) resolved in step 1, same ones handed to 3a.
- `{ASPECT_FILES}` — every reference doc in aspect's step-2 cell, each resolved to **absolute** path (spawned agents run in target repo, where relative `references/…` won't resolve).
- `{REQUIRED_SKILLS}` — that aspect's Required skills cell, comma-separated.

Either cell can be `—`: drop that cell's numbered line and renumber what's left (React drops line 2; every other in-house aspect drops line 1).

```
Adversarially review this change for {ASPECT} — treat the diff as guilty until shown correct.

Scope: {SCOPE}
1. Invoke these skills before you start reviewing and follow them — they override generic guidance: {REQUIRED_SKILLS}.
2. Read {ASPECT_FILES} and follow them exactly.
Follow through to any further skill or file the above tells you to load.
Report findings only — no code edits. Report only what survives scrutiny — no speculation padding.
Label every finding by severity and use this exact format:
  `severity — description [file:line] → concrete fix`
Severity: Critical (must fix before merge — bugs, silent failures, misleading docs, standards violations) · Important (real issue, not a blocker) · Suggestion (optional polish).
```

Step 3 done when every agent in batch has returned — 3b aspect agents **and** 3a's Standards and Spec sub-agents. Aspect agents returning is not step 3 finishing.

## 4. Aggregate

Merge in-house findings and Matt's **Standards** axis into one report, deduped, grouped by severity labels above. Matt's Standards axis has no severity labels — it splits findings into hard violations and judgement calls. Map on way in: hard violation → Critical, judgement call → Suggestion, unless finding plainly worse than its bucket suggests.

Present Matt's **Spec** axis as own section, un-merged. That section never absent: if delegated track didn't run, section says so instead of being omitted, so skipped Spec axis can't be mistaken for clean one. Every aspect selected in step 2 appears in report — state "no findings" explicitly where aspect ran clean. Close with recommended action order.