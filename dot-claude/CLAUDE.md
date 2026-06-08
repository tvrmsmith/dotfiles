# Global Agent Instructions

## Repository Layout

- Personal repos under `~/dev/personal/` (e.g. `~/dev/personal/dotfiles`, `~/dev/personal/oh-my-pi`, `~/dev/personal/ralph`)
- Work repos elsewhere under `~/dev/`

## Git Configuration

- `~/.gitconfig` uses `includeIf "gitdir:~/dev/personal/"` to auto-load `~/.gitconfig-personal`, sets personal `user.name`, `user.email` (`tvrmsmith@gmail.com`), personal SSH signing key
- Repos cloned under `~/dev/personal/` auto-get personal identity — no per-repo `git config` needed
- `GITHUB_TOKEN` provided by 1Password CLI plugin. Directory-aware:
  - **Outside `~/dev/personal/`**: authenticates as work account (`TrevorSmith-Wellsky`) — use `github.com` directly for remotes and `gh` commands
  - **Inside `~/dev/personal/`**: authenticates as personal account (`tvrmsmith`) — use `github-personal` SSH host alias for remotes, `gh auth switch --user tvrmsmith` before `gh` commands (PRs, issues, etc.)
- Running `gh` commands against work repos from inside `~/dev/personal/` → `cd` to non-personal directory first (e.g. `cd ~/dev && gh repo view ...`)
- Push fails with "Permission denied" → use `git-ssh-fix` skill

## Working with Repositories

Before cloning/checking out repo to temp location, search for existing local copy under `~/dev` (recursively):

```bash
find ~/dev -maxdepth 4 -type d -name "<repo-name>" 2>/dev/null
```

Match found → use existing copy instead of cloning. No match → clone to temp location. Personal repos → place under `~/dev/personal/` so `includeIf` identity applies automatically.

## Communication Style

- Always use `caveman` skill in **lite** mode — no filler, no hedging, professional but tight

## Planning

- Never use plan mode (`EnterPlanMode`). For any creative/feature/design work, invoke `superpowers:brainstorming` skill instead — always, before implementation.
- Trigger words ("build/add/implement/design/create X", "fix Y") → brainstorming skill, not plan mode.

## Tool Preferences

- Prefer ripgrep (`rg`) over `grep` — use Grep tool or `rg` via Bash
- Git commit messages → use `caveman:caveman-commit` skill for terse, conventional commit format. Never add `Co-Authored-By` attribution lines.
- JIRA operations → use `acli jira` (see `acli` skill for commands). Single commands (view, search) run directly in main thread. Multi-step operations (create + link, bulk edits) use subagent. Do NOT use `shared:jira-connector` agent — it is only for sandbox environments where acli is unavailable
- Never use MCP servers — use built-in tools, skills, and agents instead