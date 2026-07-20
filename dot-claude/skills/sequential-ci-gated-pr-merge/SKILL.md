---
name: sequential-ci-gated-pr-merge
description: Merge a set/train of GitHub PRs one at a time in dependency order, waiting on required CI checks and re-syncing each branch from main as it advances, never admin-bypassing. Triggers on "merge these PRs", "merge train", "merge the PR set", "land these PRs in order".
---
# Sequential CI-Gated PR Merge Loop

Merge ordered set of GitHub PRs one at a time. Per PR: sync from main, wait until mergeable with required checks green (via background `pr-monitor.sh`), then squash-merge. Each merge advance main, so every later PR need at least one re-sync. Never bypass required checks.

Live, side-effecting workflow — merge real PRs. No speculative runs.

## Policy (non-negotiable)

- **NEVER** `gh pr merge --admin`. Never bypass, override, or force past required checks.
- Always let required checks pass before merge.
- Re-sync PR branch from main via `gh pr update-branch <pr>` whenever it go BEHIND. Main busy, advance constantly.
- **Cap at 4 update-from-main iterations per PR.** After 4th, STOP and ask user — hot repo otherwise loop forever.
- Merge as soon as PR mergeable AND required checks green. Non-applicable checks reporting "skipping" fine — no wait. Only genuine required checks in `pending`/`fail`/`error` matter.
- **Monitor is authoritative on required-vs-optional.** It reads the required set from the branch rulesets and labels every not-green check `[required]`/`[optional]` — do NOT re-guess from check names or from `gh`'s `isRequired` (null here). A `[required]` check pending/failing keeps the PR out of `UNSTABLE` (it shows `BLOCKED`, or `CHECK_FAILED` on fail). Only `[optional]` checks ever surface under `UNSTABLE`.
- **You decide merge-vs-wait on each optional check.** `UNSTABLE` = required gate satisfied, PR mergeable, but the monitor listed `[optional]` checks still pending/failing. For each, map it to paths changed in PR (`gh pr diff <pr> --name-only`): if it exercises a service/area the PR touched (e.g. PR edits web-bff and `hospice-web-bff-api` is pending), **wait for green** — no merge past. Merge past a not-green optional check only when genuinely unrelated to PR changes, or systemic (see systemic-failure rule below).
- **Systemic / pre-existing non-required failures may be merged past.** Non-required check *also* failing on `main` (e.g. infra stack like `spacelift/*` — confirm via `gh api repos/<repo>/commits/main/check-runs`) is environment issue, not caused by this PR, and no touch service PR edits → safe to merge past. Confirm both conditions (failing on main AND unrelated to changed paths) before doing so.
- Merge set **sequentially**, one at a time, in given dependency order. Each merge advance main, so every subsequent PR need at least one `update-branch`.
- Default merge command: `gh pr merge <pr> --squash --delete-branch`.

## Procedure (per PR, in the given order)

Per PR in set, in order, start `iteration=1`:

1. **Sync from main:** `gh pr update-branch <pr> --repo <repo>`.
2. **Monitor:** run `pr-monitor.sh <pr> <repo>` in background. Poll every 30s, exit with `RESULT=` line + exit code. Act on result:
   - `RESULT=CLEAN` (exit 0) → mergeable, required checks green, up to date → **merge** (step 3), then next PR.
   - `RESULT=UNSTABLE` (exit 15) → required gate SATISFIED (monitor prints `required-gate: SATISFIED`); the listed checks are the ones still not green, each labeled `[required]`/`[optional]` — under `UNSTABLE` they are all `[optional]`. For each optional check, map it to PR changed paths (`gh pr diff <pr> --name-only`): if it applies to a service the PR edited (e.g. `hospice-web-bff-api` when PR touches web-bff), **poll to green** before merge — no merge past. Merge past a not-green optional check only when systemic (also failing on `main`) OR unrelated to changed paths. Re-check `mergeStateStatus`/main-HEAD immediately before merge, since wait may have let main advance.
   - `RESULT=MAIN_ADVANCED` / `RESULT=BEHIND` (exit 10) → main moved or PR fell behind; current check run stale → re-`update-branch`, `iteration++`. If `iteration > 4`, STOP and ask user. Otherwise re-run monitor.
   - `RESULT=CHECK_FAILED` (exit 20) → a **required** check failed (optional failures never trigger this — they surface under `UNSTABLE`) → STOP, report to user.
   - `RESULT=CONFLICT` (exit 30) → merge conflict → STOP, report to user.
   - `RESULT=TIMEOUT` (exit 40) → 15 min elapsed, no terminal state → re-check PR state manually and decide (usually re-run monitor, or ask user if something look stuck).
3. **Merge on CLEAN:** `gh pr merge <pr> --squash --delete-branch`, then verify: `gh pr view <pr> --repo <repo> --json state` show `MERGED`. Only then next PR.

Repeat for every PR in set. Each merge advance main, so expect next PR back `BEHIND` on first monitor pass — normal, just re-sync.

## Environment gotchas

- **`gh` often aliased to `op plugin run -- gh`** (1Password). Reads work, but writes/auth can intermittently fail with "authorization timeout" — just retry command.
- **macOS bash:** only `/bin/bash` (3.2) may exist; Homebrew bash may be absent. `pr-monitor.sh` use `#!/bin/bash` shebang, stay 3.2-compatible. Some other tooling (e.g. local `imr` verify) need `PATH=/opt/homebrew/bin:$PATH` — set for those, not for monitor.
- **Worktree auth timeouts:** running `gh` from inside certain git worktrees can hit auth-timeout. Running from plain repo dir (e.g. `~/dev`) more reliable for read APIs. Always pass `--repo <owner>/<name>` explicitly so cwd no matter.
- **RTK not the problem.** RTK proxy does NOT truncate `gh` output (verified: filtered vs `rtk proxy` raw output identical line counts). If checks look missing, usually 1Password auth or GitHub status rollup still computing — not RTK.
- **`mergeStateStatus` values you see:**
  - `CLEAN` — ready to merge.
  - `BEHIND` — need sync from main.
  - `BLOCKED` — required checks pending / not yet satisfied → keep waiting.
  - `UNSTABLE` — required checks satisfied (PR *is* mergeable) but an optional check pending/failing. Do NOT auto-merge. Monitor lists each not-green check labeled `[required]`/`[optional]`; map each optional one to PR changed paths: wait on any applying to edited service; merge only once those green (systemic/unrelated failures excepted, per policy rules above).
  - `UNKNOWN` — GitHub still computing → keep waiting.
  - `DIRTY` — merge conflict.
- **Detecting main advance:** compare `gh api repos/<repo>/commits/main --jq .sha` against baseline captured at monitor start. More responsive than waiting for GitHub to flip PR to `BEHIND`. Monitor do this for you.

## Usage example

Merge ordered set `#1408 #1419 #1407 #1422` for `mediwareinc/Meridian.IMR`, one at a time:

```bash
REPO=mediwareinc/Meridian.IMR
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

Rules of thumb while running:
- One PR fully MERGED before start next.
- 5th sync needed on single PR → STOP, ask user.
- Any `CHECK_FAILED` or `CONFLICT` → STOP, report, no touch other PRs.