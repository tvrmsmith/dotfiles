---
name: personal-build-sync
description: |
  Sync a personal build of a forked app. Updates main from upstream, rebuilds
  the personal-build branch with selected feature branches rebased on top.
  Use this skill whenever the user mentions personal build, fork sync, rebuild
  personal branch, update fork, sync upstream, personal-build, or wants to
  combine feature branches onto an updated main for a custom build of a fork.
---

# Personal Build Sync

Rebuild `personal-build` branch from fresh-updated main, with selected feature branches. personal-build branch live in git worktree, sibling dir to repo.

## Overview

```
repo/                          ← main repo (main branch)
repo-personal-build/           ← worktree (personal-build branch)
```

Workflow:
1. Preflight checks (dirty tree, upstream remote)
2. Update main from upstream
3. Reset personal-build to updated main (worktree)
4. Ask which feature branches to include
5. Rebase each onto main, resolve conflicts, push branches
6. Merge each into personal-build, resolve conflicts
7. Detect stale branches (all commits already in main)

## Step 1 — Preflight

### Check for uncommitted changes

```bash
git status --porcelain
```

Output non-empty → use AskUserQuestion:
- **Stash changes** — `git stash push -m "personal-build-sync auto-stash"`
- **Commit first** — let user commit, then continue
- **Abort** — stop the skill

### Detect default branch

```bash
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||'
```

Fall back to checking if `main` or `master` exists locally. Store as `$DEFAULT_BRANCH`.

### Detect upstream remote

```bash
git remote -v
```

Check for remote named `upstream`. Missing → auto-detect fork parent via GitHub API:

```bash
REPO_OWNER=$(git remote get-url origin | sed -E 's|.*[:/]([^/]+)/[^/]+(\.git)?$|\1|')
REPO_NAME_GH=$(git remote get-url origin | sed -E 's|.*[:/][^/]+/([^/]+?)(\.git)?$|\1|')
PARENT_URL=$(gh api "repos/$REPO_OWNER/$REPO_NAME_GH" --jq '.parent.clone_url // empty' 2>/dev/null)
```

`$PARENT_URL` found → confirm with user via AskUserQuestion, then:

```bash
git remote add upstream "$PARENT_URL"
```

GitHub API fails or repo not a fork → ask user for upstream URL directly via AskUserQuestion.

Only `origin` exists and points to upstream (not a fork) → treat `origin` as upstream.

## Step 2 — Update Main

```bash
git fetch upstream
git checkout $DEFAULT_BRANCH
git merge --ff-only upstream/$DEFAULT_BRANCH
```

Fast-forward fails → local main diverged. Use AskUserQuestion:
- **Force reset** — `git reset --hard upstream/$DEFAULT_BRANCH`
- **Abort** — stop and let user resolve manually

After update, run CI checks before pushing main to origin (main is fast-forward of upstream, normally green, but verify — never push unvalidated code):

```bash
bun run lint:fix && bun run typecheck && bun test && bunx sherif --fix
```

Checks pass (and `lint:fix`/`sherif --fix` made no changes) → push main:

```bash
git push origin $DEFAULT_BRANCH
```

Auto-fixers changed files → commit onto main first, then push. `typecheck`/`test` fail on clean upstream fast-forward → stop and report — indicates local environment problem, not sync issue.

## Step 3 — Personal-Build Branch Setup

Determine paths using `pwd` (more reliable than `git rev-parse --toplevel`, which can return literal strings in some shell contexts):

```bash
REPO_DIR=$(pwd)
REPO_NAME=$(basename "$REPO_DIR")
WORKTREE_DIR="$(dirname "$REPO_DIR")/${REPO_NAME}-personal-build"
```

### If worktree already exists

Check via `git worktree list` whether worktree already at `$WORKTREE_DIR`. If so:

```bash
git -C "$WORKTREE_DIR" checkout personal-build 2>/dev/null
git -C "$WORKTREE_DIR" reset --hard $DEFAULT_BRANCH
```

### If worktree does not exist

Check if `personal-build` branch exists:

```bash
git show-ref --verify --quiet refs/heads/personal-build
```

Branch exists:
```bash
git worktree add "$WORKTREE_DIR" personal-build
git -C "$WORKTREE_DIR" reset --hard $DEFAULT_BRANCH
```

Branch does not exist:
```bash
git worktree add -b personal-build "$WORKTREE_DIR" $DEFAULT_BRANCH
```

Confirm worktree set up:
```bash
git worktree list
```

## Step 4 — Branch Selection

List all local branches excluding `$DEFAULT_BRANCH` and `personal-build`. Also check remote origin branches not yet checked out locally:

```bash
# Local branches
git branch --format='%(refname:short)' | grep -vE "^($DEFAULT_BRANCH|personal-build)$"

# Remote-only branches (on origin, not yet local)
git branch -r --format='%(refname:short)' | grep '^origin/' | sed 's|^origin/||' \
  | grep -vE "^($DEFAULT_BRANCH|personal-build|HEAD)$"
```

Check out any remote-only branches locally before proceeding:

```bash
git checkout --track "origin/<branch>"
```

Use AskUserQuestion with **multiSelect: true**. Options:
- **"All branches"** — select everything
- Each branch name as individual option (show up to ~15; if more, list them and let user type names)

No feature branches → report personal-build identical to main and stop.

## Step 5 — Rebase, Push, and Merge Each Branch

Process branches one at a time, in order selected.

For each branch:

### 5a. Rebase onto main

```bash
git checkout <branch>
git rebase --empty=drop $DEFAULT_BRANCH
```

**Always resolve conflicts.** Rebase conflict → read both sides of each conflicting file, understand intent of each change, resolve by combining both sides where they add independent content (e.g. different fields, imports, settings entries). Use Read and Edit tools to fix each conflicting file, then `git add` and `git rebase --continue`. Repeat for every conflicting commit until rebase completes.

Do not ask user whether to resolve — always resolve. Only ask user if conflict genuinely ambiguous (both sides modify same logic in incompatible ways and correct resolution unclear).

### 5b. Run CI checks

After successful rebase, run project CI checks **before pushing**. These mirror `ci-check` command (`.agents/commands/ci-check.md`). Run all four in parallel from repo root:

```bash
bun run lint:fix      # Biome formatting + linting (auto-fixes)
bun run typecheck     # TypeScript type checking across all packages
bun test              # Run all tests
bunx sherif --fix     # Monorepo dependency linting (auto-fixes)
```

**Always fix failures before pushing.** `lint:fix` or `sherif --fix` auto-fixed files → amend into appropriate commit (or add fixup) so pushed branch clean. `typecheck` or `test` fail → read errors and fix — usually caused by rebase replaying commits onto new main code. Re-run failing check until passes cleanly, zero warnings (CI treats warnings as errors).

Only ask user if failure genuinely ambiguous or requires product decision. **Branch with failing checks must NOT be pushed to origin OR merged into personal-build** — checks gate both. Block on 5b until green.

### 5c. Push the rebased branch

After checks pass, push updated branch to origin. Rebase rewrites history → use `--force-with-lease` to safely force-push:

```bash
git push --force-with-lease origin <branch>
```

### 5d. Check for empty result

```bash
AHEAD=$(git rev-list $DEFAULT_BRANCH..<branch> --count)
```

`$AHEAD` is 0 → all commits already in main. Use AskUserQuestion:
- **Delete branch** — `git push origin --delete <branch>` then `git branch -D <branch>`
- **Keep branch** — leave it, skip merging

### 5e. Merge into personal-build

Commits remain:

```bash
git -C "$WORKTREE_DIR" merge --no-ff <branch> -m "Merge <branch> into personal-build"
```

**Always resolve merge conflicts.** Same approach as rebase conflicts — read both sides, combine independent additions, commit resolution. These conflicts typically arise when multiple feature branches touch same files (e.g. both add settings entries, schema columns, imports). Resolution almost always to keep both additions.

Do not ask user whether to resolve — always resolve. Only ask if conflict genuinely ambiguous.

## Step 6 — CI Check, Push, and Summary

After all branches merged, run CI checks one final time **in the worktree** to validate combined result (merge conflict resolutions can introduce issues no single branch had):

```bash
cd "$WORKTREE_DIR"
bun run lint:fix && bun run typecheck && bun test && bunx sherif --fix
```

Fix any failures and commit fixes onto personal-build before pushing. Then push personal-build branch to origin:

```bash
git -C "$WORKTREE_DIR" push --force-with-lease origin personal-build
```

After all branches processed, report:

- Branches merged into personal-build
- Branches skipped (user choice)
- Branches deleted (empty after rebase)
- Conflicts resolved (count per branch)
- Worktree location

```
Personal build ready at: /path/to/repo-personal-build
Merged: feature-a, feature-b, feature-c
Deleted (stale): old-feature
Conflicts resolved: feature-a (2 files), feature-b (6 files)
Pushed: main, feature-a, feature-b, fix-c, personal-build
```

Return to $DEFAULT_BRANCH in main repo when done:
```bash
git checkout $DEFAULT_BRANCH
```