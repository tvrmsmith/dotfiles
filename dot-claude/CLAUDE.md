# Global Claude Instructions

## Git Configuration

### Personal Repository SSH Setup

**For repositories under `tvrmsmith/*` (personal repos):**
- Must use `github-personal` SSH host alias instead of `github.com`
- SSH keys are managed by 1Password (see `~/.ssh/config` and `~/.ssh/1Password/config`)

**If you get "Permission denied" when pushing to a tvrmsmith/* repository:**
```bash
# Check current remote URL
git remote -v

# If it shows github.com instead of github-personal, fix it:
git remote set-url origin git@github-personal:tvrmsmith/<repo-name>.git

# Verify and push
git remote -v
git push -u origin <branch-name>
```

**For work repositories (non-tvrmsmith):**
- Use `github.com` directly (default behavior)

## Tool Preferences

### Search Tools

**Prefer ripgrep (`rg`) over `grep`:**
- When searching for patterns in files, use `rg` instead of `grep`
- Ripgrep is faster, has better defaults, and respects `.gitignore`
- Use the Grep tool which is built on ripgrep, or use `rg` via Bash when needed