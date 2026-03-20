# Global Claude Instructions

## Git Configuration

- For `tvrmsmith/*` repos: use `github-personal` SSH host alias instead of `github.com`
- For work repos (non-tvrmsmith): use `github.com` directly
- If push fails with "Permission denied", use the `git-ssh-fix` skill

## Tool Preferences

- Prefer ripgrep (`rg`) over `grep` — use the Grep tool or `rg` via Bash
- For JIRA operations, use `acli jira` — see the `jira` skill for command reference

