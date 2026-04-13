# Global Agent Instructions

## Git Configuration

- For `tvrmsmith/*` repos: use `github-personal` SSH host alias instead of `github.com`
- For `tvrmsmith/*` repos: use the `tvrmsmith` gh CLI account — run `gh auth switch --user tvrmsmith` before any `gh` commands (PRs, issues, etc.)
- For work repos (non-tvrmsmith): use `github.com` directly with the `TrevorSmith-Wellsky` account
- If push fails with "Permission denied", use the `git-ssh-fix` skill

## Working with Repositories

Before cloning or checking out a repository to a temporary location, first search for an existing local copy under `~/dev` (recursively). Use a command like:

```bash
find ~/dev -maxdepth 3 -type d -name "<repo-name>" 2>/dev/null
```

If a match is found, use the existing local copy instead of cloning. Only clone to a temporary location if no local copy exists.

## Communication Style

- Always use the `caveman` skill in **lite** mode — no filler, no hedging, professional but tight

## Tool Preferences

- Prefer ripgrep (`rg`) over `grep` — use the Grep tool or `rg` via Bash
- For JIRA operations, use `acli jira` — see the `jira` skill for command reference
- For Confluence operations, use the `ws-atlassian` skill (TypeScript-based) instead of `acli`

