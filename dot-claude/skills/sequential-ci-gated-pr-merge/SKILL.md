---
name: sequential-ci-gated-pr-merge
description: Merge a set/train of GitHub PRs one at a time in dependency order, waiting on required CI checks and re-syncing each branch from its base branch as it advances, never admin-bypassing. Triggers on "merge these PRs", "merge train".
---
# Sequential CI-Gated PR Merge Loop

Merge ordered set of GitHub PRs one at a time. Per PR: sync from base branch, wait until mergeable with required checks green (via background `pr-monitor.sh`), then squash-merge. Never bypass required checks.

Live, side-effecting workflow — merge real PRs. No speculative runs.

## Policy (non-negotiable)

- **NEVER** `gh pr merge --admin`. Never bypass, override, or force past required checks.
- Always let required checks pass before merge.
- **Each merge advances its base branch**, so later PRs on that same base need at least one re-sync before they can go green. Whenever a PR goes BEHIND, re-sync it: `gh pr update-branch <pr> --repo <repo>`.
- **Cap at 4 update-from-base iterations per PR.** After the 4th, STOP and ask user — hot repo otherwise loops forever.
- Merge as soon as PR mergeable AND required checks green. Non-applicable checks reporting "skipping" fine — no wait. Only genuine required checks in `pending`/`fail`/`error` matter.
- **Monitor is authoritative on required-vs-optional.** It reads the required set from the branch rulesets and labels every not-green check `[required]`/`[optional]` — do NOT re-guess from check names or from `gh`'s `isRequired` (null here). A `[required]` check pending/failing keeps the PR out of `UNSTABLE` (it shows `BLOCKED`, or `CHECK_FAILED` on fail). Only `[optional]` checks ever surface under `UNSTABLE`.
- **Optional-check mapping rule (UNSTABLE handling).** `UNSTABLE` = required gate satisfied, PR mergeable, but the monitor listed `[optional]` checks still pending/failing. For each, map it to paths changed in PR (`gh pr diff <pr> --name-only`): if it exercises a service/area the PR touched (e.g. PR edits web-bff and `hospice-web-bff-api` is pending), **wait for green** — no merge past. Merge past a not-green optional check only when genuinely unrelated to PR changes, or systemic (see next bullet).
- **Systemic / pre-existing non-required failures may be merged past.** Non-required check *also* failing on the base branch (e.g. infra stack like `spacelift/*` — confirm via `gh api repos/<repo>/commits/<base>/check-runs`) is environment issue, not caused by this PR. Merge past only if it's both failing on the base branch AND unrelated to changed paths — confirm both before doing so.
- Merge set **sequentially**, one at a time, in given dependency order.
- Default merge command: `gh pr merge <pr> --squash --delete-branch`.

## Procedure (per PR, in the given order)

Per PR in set, in order, start `iteration=1`:

1. **Sync from base branch:** `gh pr update-branch <pr> --repo <repo>`.
2. **Monitor:** run `pr-monitor.sh <pr> <repo>` in background. Poll every 30s, exit with `RESULT=` line + exit code. Act on result:
   - `RESULT=CLEAN` (exit 0) → mergeable, required checks green, up to date → **merge** (step 3), then next PR.
   - `RESULT=UNSTABLE` (exit 15) → required gate SATISFIED (monitor prints `required-gate: SATISFIED`) → apply the optional-check mapping rule in Policy before merging. Re-check `mergeStateStatus`/base-HEAD immediately before merge, since the wait may have let the base branch advance.
   - `RESULT=MAIN_ADVANCED` / `RESULT=BEHIND` (exit 10) → main moved or PR fell behind; current check run stale → re-`update-branch`, `iteration++`. If `iteration > 4`, STOP and ask user. Otherwise re-run monitor.
   - `RESULT=CHECK_FAILED` (exit 20) → a **required** check failed (optional failures never trigger this — they surface under `UNSTABLE`) → STOP, report to user.
   - `RESULT=CONFLICT` (exit 30) → merge conflict → STOP, report to user.
   - `RESULT=TIMEOUT` (exit 40) → 15 min elapsed, no terminal state → re-check PR state manually and decide (usually re-run monitor, or ask user if something looks stuck).
   - `RESULT=REQUIRED_UNKNOWN` (exit 50) → monitor could not read the base branch's required-check set, so it cannot label required-vs-optional → STOP, report to user, do NOT merge. Fix the cause (token scope to read rulesets/branch protection, or confirm base branch) then re-run.
3. **Merge on CLEAN:** `gh pr merge <pr> --squash --delete-branch`, then verify: `gh pr view <pr> --repo <repo> --json state` shows `MERGED`. Only then next PR.

Repeat for every PR in set — expect the next PR back `BEHIND` on first monitor pass (the base branch just advanced, per Policy); re-sync and continue.

## mergeStateStatus reference

- `CLEAN` — ready to merge.
- `BEHIND` — need sync from base branch.
- `BLOCKED` — required checks pending / not yet satisfied → keep waiting.
- `UNSTABLE` — required checks satisfied (PR *is* mergeable) but an optional check pending/failing → apply the optional-check mapping rule in Policy. Do NOT auto-merge.
- `UNKNOWN` — GitHub still computing → keep waiting.
- `DIRTY` — merge conflict.

**Detecting main advance:** compare `gh api repos/<repo>/commits/<base> --jq .sha` against baseline captured at monitor start. More responsive than waiting for GitHub to flip PR to `BEHIND`. Monitor does this for you.

Environment-specific gotchas (1Password/`gh` aliasing, worktree auth, macOS bash 3.2): see [environment.md](environment.md).

## Usage example

Merge ordered set `#1408 #1419 #1407 #1422` for `mediwareinc/Redacted.Repo`, one at a time:

```bash
REPO=mediwareinc/Redacted.Repo
SKILL=~/.claude/skills/sequential-ci-gated-pr-merge

# --- PR 1408 (iteration 1) ---
gh pr update-branch 1408 --repo "$REPO"
bash "$SKILL/pr-monitor.sh" 1408 "$REPO"   # run in background; read the RESULT= line
# RESULT=CLEAN → merge:
gh pr merge 1408 --squash --delete-branch --repo "$REPO"
gh pr view 1408 --repo "$REPO" --json state   # expect MERGED

# --- PR 1419 (will be BEHIND now — 1408 advanced main) ---
gh pr update-branch 1419 --repo "$REPO"
bash "$SKILL/pr-monitor.sh" 1419 "$REPO"
# RESULT=BEHIND → gh pr update-branch 1419 (iteration 2), re-run monitor
# RESULT=CLEAN → gh pr merge 1419 --squash --delete-branch --repo "$REPO"

# ...then #1407, then #1422, same pattern.
```
