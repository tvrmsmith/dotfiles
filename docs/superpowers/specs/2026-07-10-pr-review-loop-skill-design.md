# pr-review-loop skill — design

**Date:** 2026-07-10
**Status:** Approved (pending spec review)

## Problem

The existing `review-loop` skill runs a review command itself (e.g. `pr-review-toolkit:review-pr`) against the local `git diff`, then loops fix→re-review locally. But PRs in these repos already receive an **automatic Claude review** posted by an `@claude` GitHub Actions workflow. That bot review is the authoritative source of findings for the PR. Re-running a local review duplicates work and doesn't converge against what the PR's own automated reviewer will flag.

We want a loop that:

1. Reads the Claude bot's review already on the PR as the source of findings (no local review run).
2. Triages and fixes those findings in a subagent.
3. Commits and pushes to the PR branch.
4. Posts an `@claude` comment to re-trigger the bot review.
5. Waits for the fresh review, then repeats — until the review is clean, iterations cap out, or the wait times out.

## Non-goals

- Not modifying `review-loop`. It stays generic: any review command, local `git diff`, no side effects (no commit/push/comment). This new skill is the GitHub-specific, side-effecting, async-polling variant.
- Not running any local review command. The PR's Claude bot review is the only source of findings.
- Not managing PR creation, merge, or CI beyond re-triggering the Claude review.

## Identity & shape

- **Name:** `pr-review-loop`
- **Location:** `dot-claude/skills/pr-review-loop/SKILL.md` (stowed to `~/.claude/skills/`).
- **Triggers:** "PR review loop", "loop the Claude PR review", "fix the Claude review on this PR".
- Borrows `review-loop`'s triage + fix-subagent patterns; adds fetch-from-PR, commit/push, `@claude` re-trigger, and async polling.

## Config parse

Free-form natural-language args. Extract optional elements; fall back to defaults:

| Element | Default | Examples |
|---------|---------|----------|
| PR | current branch's open PR (`gh pr view`) | "PR 42", a PR URL |
| Max iterations | `4` | "max 6", "3x" |
| Poll timeout (per re-review) | `15m` | "wait up to 30m" |
| Poll interval | `30s` | "poll every 60s" |
| Focus | none | "focus on error handling" — passed as guidance in the `@claude` re-request and to triage |

After parsing, echo resolved config in one line before anything else:

```
PR: <#/url> · Max: <n> · Poll: <interval>/<timeout> · Focus: <focus or "none">
```

### Auth & directory awareness

Follows the user's global git rules (`~/.claude/CLAUDE.md`):

- Inside `~/dev/personal/`: personal identity, `github-personal` remote, `gh auth switch --user tvrmsmith` before `gh` calls.
- Outside: work account, `github.com` direct.
- `gh` against a work repo from inside `~/dev/personal/` → `cd` out first.
- Push fails `Permission denied` → invoke `git-ssh-fix` skill.

## The loop

Repeat each iteration until a stop condition (see below) holds. Track iteration number against max.

### 3a. Fetch the Claude bot review (main thread, `gh`)

Pull the newest Claude-bot review on the PR from **both** sources:

- PR reviews + review comments: `gh api repos/{owner}/{repo}/pulls/{n}/reviews` and `.../comments`.
- Issue comments: `gh pr view {n} --json comments`.

**Bot author detection:** match author login against `claude[bot]` / `github-actions[bot]` (and `...` type `Bot`). On the first run, if the author is ambiguous or nothing matches, inspect the PR once and confirm the correct bot author with the user via `AskUserQuestion` before proceeding; remember the choice for the rest of the run.

**Iteration 1** uses the review already present on the PR (the automatic one — no trigger needed). Later iterations use the review that landed in step 3h.

**Selecting "the review":** the newest bot-authored review/comment that carries actual review content (findings and/or a verdict), not a bare acknowledgment (e.g. "on it 👀" / progress placeholder). See the detection heuristic in 3h.

### 3b. Parse → condensed findings

Reduce the fetched review to a condensed list, one line per finding:

```
path:line · severity · problem · suggested fix
```

Keep raw review bodies out of the main thread beyond this reduction.

### 3c. Triage

Classify each finding:

- **Clear** — high-value, unambiguous. Auto-approved; not surfaced.
- **Ambiguous / unnecessary** — risky, low-value, or judgment call. Surface to user.

Dedupe against the running **deferred set** from prior iterations — never re-surface a finding the user already deferred.

### 3d. Decision gate

If any ambiguous/unnecessary findings this iteration, present with `AskUserQuestion` (group related findings; split into sequential questions if over one question's capacity; each option is fix or skip). Clear findings are not shown. Approved set = clear findings + ambiguous findings the user chose to fix. Findings the user declined are added to the deferred set. If every finding is clear, skip the question and go straight to 3e.

### 3e. Fix dispatch

Apply approved findings via subagent(s):

- **Small set** → one fix subagent takes the whole batch, applies edits, reports what changed.
- **Large set** → split into per-file / per-area batches, one subagent each, parallel **only** where edits cannot conflict (never two subagents on the same file).

Subagents load `coding-standards` skill before editing (per global instructions).

### 3f. Commit + push

- **One commit per iteration:** squash the round's fixes into a single commit, message via `caveman:caveman-commit` style (no `Co-Authored-By`).
- Push to the PR branch. On `Permission denied` → `git-ssh-fix` skill, then retry.

### 3f-bis. Reply to comments & resolve threads

For each inline review-thread comment acted on this iteration:

- **Fixed** → post a **very concise** reply on the thread (e.g. `Fixed in <sha>.`), then resolve the thread.
- **Deferred** → post a concise reply noting the reason, and **leave the thread unresolved** so it stays visible.

Mechanics: inline review comments live in review threads, resolved via the GraphQL `resolveReviewThread` mutation. Thread IDs come from the `pullRequest.reviewThreads` GraphQL query (`gh api graphql`). General issue comments (non-thread) have no resolve concept — reply is optional and skipped by default.

### 3g. Re-request review

Post a PR comment containing `@claude` (append focus guidance if set), e.g.:

```
@claude please re-review — pushed fixes for the findings above.
```

Record the trigger comment's `createdAt` timestamp.

### 3h. Poll for the fresh review

Poll for a **new** bot review/comment with `createdAt` (or `submittedAt`) newer than the trigger timestamp, every poll interval until poll timeout.

**Landed vs. acknowledgment heuristic:** a post-trigger bot comment counts as the review only when its body carries review structure (findings, a verdict, or inline review comments) — not a bare acknowledgment or in-progress placeholder. The bot commonly edits one comment in place (ack → review), so apply a short **settle delay** (a few poll intervals of no change, or the comment gaining review structure) before treating it as final.

- Review lands → parse (back to 3b for next iteration).
- **Poll timeout** → `AskUserQuestion`: (a) keep waiting (extend by the timeout again), (b) stop and report, (c) check the Actions run. Interactive; do not silently abort.

### 3i. Iteration summary

After each iteration, print one line:

```
Iter <i>/<max>: <total> findings · <fixed> fixed · <deferred> deferred · pushed <sha>
```

Then evaluate stop conditions. If none hold, continue to next iteration at 3a (using the review that landed in 3h).

## Stop conditions & state

Stop when ANY holds:

- Iteration count reaches max.
- Fetched review returns **no actionable findings** (clean review).
- Only findings left are already in the deferred set (no progress possible).
- Poll times out **and** the user chose "stop" at the timeout gate.

**State across iterations:** maintain the running deferred set. Once a finding is deferred, never surface it again this run; only genuinely new findings trigger the decision gate on later iterations.

## Final report

On exit, print:

- Total iterations run.
- Total findings fixed.
- Deferred list, each with reason.
- Stop reason (max reached / clean review / only deferred remain / user stopped at timeout).
- PR link.

## Open risks

- **Review-landed detection** is the fragile part: distinguishing the real re-review from the bot's acknowledgment/edit-in-place. Mitigated by the review-structure heuristic + settle delay, and the interactive timeout gate as a backstop.
- **Bot author identity** varies by repo/workflow config; handled by auto-detect + one-time user confirmation on ambiguity.
- **Auto-review on push:** a push may itself trigger a review independent of the `@claude` comment; the newest-post-trigger selection tolerates either source.
