---
name: git-ssh-fix
description: Use when pushing to tvrmsmith/* repositories fails with "Permission denied", or when setting up remotes for personal GitHub repos. Triggers on: permission denied, git push failed, tvrmsmith, github-personal, SSH key error.
---

# Git SSH Fix for Personal Repos

Repositories under `tvrmsmith/*` must use the `github-personal` SSH host alias instead of `github.com`. SSH keys are managed by 1Password (see `~/.ssh/config` and `~/.ssh/1Password/config`).

## Diagnosis and Fix

```bash
# Check current remote URL
git remote -v

# If it shows github.com instead of github-personal, fix it:
git remote set-url origin git@github-personal:tvrmsmith/<repo-name>.git

# Verify and push
git remote -v
git push -u origin <branch-name>
```

## Rules

- `tvrmsmith/*` repos: use `github-personal` host alias
- Work repos (non-tvrmsmith): use `github.com` directly (default)
