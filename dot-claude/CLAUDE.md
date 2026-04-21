# Global Agent Instructions

## Repository Layout

- Personal repos live under `~/dev/personal/` (e.g. `~/dev/personal/dotfiles`, `~/dev/personal/oh-my-pi`, `~/dev/personal/ralph`)
- Work repos live elsewhere under `~/dev/`

## Git Configuration

- `~/.gitconfig` uses `includeIf "gitdir:~/dev/personal/"` to auto-load `~/.gitconfig-personal`, which sets the personal `user.name`, `user.email` (`tvrmsmith@gmail.com`), and personal SSH signing key
- Any repo cloned under `~/dev/personal/` automatically gets the personal identity — no per-repo `git config` needed
- For repos under `~/dev/personal/` (typically `tvrmsmith/*`): use `github-personal` SSH host alias instead of `github.com` when setting remotes
- For repos under `~/dev/personal/`: use the `tvrmsmith` gh CLI account — run `gh auth switch --user tvrmsmith` before any `gh` commands (PRs, issues, etc.)
- For work repos: use `github.com` directly with the `TrevorSmith-Wellsky` account
- If push fails with "Permission denied", use the `git-ssh-fix` skill

## Working with Repositories

Before cloning or checking out a repository to a temporary location, first search for an existing local copy under `~/dev` (recursively). Use a command like:

```bash
find ~/dev -maxdepth 4 -type d -name "<repo-name>" 2>/dev/null
```

If a match is found, use the existing local copy instead of cloning. Only clone to a temporary location if no local copy exists. When cloning a personal repo, place it under `~/dev/personal/` so the `includeIf` identity applies automatically.

## Communication Style

- Always use the `caveman` skill in **lite** mode — no filler, no hedging, professional but tight

## Tool Preferences

- Prefer ripgrep (`rg`) over `grep` — use the Grep tool or `rg` via Bash
- For JIRA operations, use `acli jira` — see the `jira` skill for command reference
- For Confluence operations, use the `ws-atlassian` skill (TypeScript-based) instead of `acli`
