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

Rebuild a `personal-build` branch from a freshly-updated main, incorporating
selected feature branches. The personal-build branch lives in a git worktree
that is a sibling directory to the repo.

## Overview

```
repo/                          ← main repo (main branch)
repo-personal-build/           ← worktree (personal-build branch)
```

The workflow:
1. Preflight checks (dirty tree, upstream remote)
2. Update main from upstream
3. Reset personal-build branch to updated main (worktree)
4. Ask which feature branches to include
5. Rebase each onto main, resolve conflicts, push updated branches
6. Merge each into personal-build, resolve conflicts
7. Detect stale branches (all commits already in main)

## Step 1 — Preflight

### Check for uncommitted changes

```bash
git status --porcelain
```

If output is non-empty, use AskUserQuestion:
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

Check for a remote named `upstream`. If missing, try to auto-detect the fork
parent via GitHub API:

```bash
REPO_OWNER=$(git remote get-url origin | sed -E 's|.*[:/]([^/]+)/[^/]+(\.git)?$|\1|')
REPO_NAME_GH=$(git remote get-url origin | sed -E 's|.*[:/][^/]+/([^/]+?)(\.git)?$|\1|')
PARENT_URL=$(gh api "repos/$REPO_OWNER/$REPO_NAME_GH" --jq '.parent.clone_url // empty' 2>/dev/null)
```

If `$PARENT_URL` is found, confirm with the user via AskUserQuestion, then:

```bash
git remote add upstream "$PARENT_URL"
```

If GitHub API fails or repo is not a fork, ask the user for the upstream URL
directly via AskUserQuestion.

If only `origin` exists and it points to the upstream (not a fork), treat
`origin` as upstream.

## Step 2 — Update Main

```bash
git fetch upstream
git checkout $DEFAULT_BRANCH
git merge --ff-only upstream/$DEFAULT_BRANCH
```

If fast-forward fails, the local main has diverged. Use AskUserQuestion:
- **Force reset** — `git reset --hard upstream/$DEFAULT_BRANCH`
- **Abort** — stop and let user resolve manually

After updating, push main to origin:

```bash
git push origin $DEFAULT_BRANCH
```

## Step 3 — Personal-Build Branch Setup

Determine paths using `pwd` (more reliable than `git rev-parse --toplevel`
which can return literal strings in some shell contexts):

```bash
REPO_DIR=$(pwd)
REPO_NAME=$(basename "$REPO_DIR")
WORKTREE_DIR="$(dirname "$REPO_DIR")/${REPO_NAME}-personal-build"
```

### If worktree already exists

Check via `git worktree list` whether there is already a worktree at
`$WORKTREE_DIR`. If so:

```bash
git -C "$WORKTREE_DIR" checkout personal-build 2>/dev/null
git -C "$WORKTREE_DIR" reset --hard $DEFAULT_BRANCH
```

### If worktree does not exist

Check if the `personal-build` branch exists:

```bash
git show-ref --verify --quiet refs/heads/personal-build
```

If branch exists:
```bash
git worktree add "$WORKTREE_DIR" personal-build
git -C "$WORKTREE_DIR" reset --hard $DEFAULT_BRANCH
```

If branch does not exist:
```bash
git worktree add -b personal-build "$WORKTREE_DIR" $DEFAULT_BRANCH
```

Confirm the worktree is set up:
```bash
git worktree list
```

## Step 4 — Branch Selection

List all local branches excluding `$DEFAULT_BRANCH` and `personal-build`.
Also check for remote origin branches not yet checked out locally:

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
- Each branch name as an individual option (show up to ~15; if more, list them
  and let the user type names)

If no feature branches exist, report that personal-build is identical to main
and stop.

## Step 5 — Rebase, Push, and Merge Each Branch

Process branches one at a time, in the order selected.

For each branch:

### 5a. Rebase onto main

```bash
git checkout <branch>
git rebase --empty=drop $DEFAULT_BRANCH
```

**Always resolve conflicts.** When rebase conflicts occur, read both sides of
each conflicting file, understand the intent of each change, and resolve by
combining both sides where they add independent content (e.g. different fields,
different imports, different settings entries). Use the Read and Edit tools to
fix each conflicting file, then `git add` and `git rebase --continue`. Repeat
for every conflicting commit until the rebase completes.

Do not ask the user whether to resolve — always resolve. Only ask the user if
a conflict is genuinely ambiguous (both sides modify the same logic in
incompatible ways and the correct resolution is unclear).

### 5b. Push the rebased branch

After a successful rebase, push the updated branch to origin. Since rebase
rewrites history, use `--force-with-lease` to safely force-push:

```bash
git push --force-with-lease origin <branch>
```

### 5c. Check for empty result

```bash
AHEAD=$(git rev-list $DEFAULT_BRANCH..<branch> --count)
```

If `$AHEAD` is 0, all commits were already in main. Use AskUserQuestion:
- **Delete branch** — `git push origin --delete <branch>` then `git branch -D <branch>`
- **Keep branch** — leave it, skip merging

### 5d. Merge into personal-build

If commits remain:

```bash
git -C "$WORKTREE_DIR" merge --no-ff <branch> -m "Merge <branch> into personal-build"
```

**Always resolve merge conflicts.** Same approach as rebase conflicts — read
both sides, combine independent additions, and commit the resolution. These
conflicts typically arise when multiple feature branches touch the same files
(e.g. both add settings entries, schema columns, or imports). The resolution
is almost always to keep both additions.

Do not ask the user whether to resolve — always resolve. Only ask if the
conflict is genuinely ambiguous.

## Step 6 — Push and Summary

Push the personal-build branch to origin:

```bash
git -C "$WORKTREE_DIR" push --force-with-lease origin personal-build
```

After all branches are processed, report:

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

Return to $DEFAULT_BRANCH in the main repo when done:
```bash
git checkout $DEFAULT_BRANCH
```
