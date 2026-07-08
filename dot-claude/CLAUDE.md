# Global Agent Instructions

## Repository Layout

- Personal repos under `~/dev/personal/` (e.g. `~/dev/personal/dotfiles`, `~/dev/personal/oh-my-pi`, `~/dev/personal/ralph`)
- Work repos elsewhere under `~/dev/`

## Git Configuration

- `~/.gitconfig` uses `includeIf "gitdir:~/dev/personal/"` to auto-load `~/.gitconfig-personal`, sets personal `user.name`, `user.email` (`tvrmsmith@gmail.com`), personal SSH signing key
- Repos cloned under `~/dev/personal/` auto-get personal identity — no per-repo `git config` needed
- `GITHUB_TOKEN` from 1Password CLI plugin. Directory-aware:
  - **Outside `~/dev/personal/`**: auth as work account (`TrevorSmith-Wellsky`) — use `github.com` direct for remotes and `gh` commands
  - **Inside `~/dev/personal/`**: auth as personal account (`tvrmsmith`) — use `github-personal` SSH host alias for remotes, `gh auth switch --user tvrmsmith` before `gh` commands (PRs, issues, etc.)
- `gh` commands against work repos from inside `~/dev/personal/` → `cd` to non-personal directory first (e.g. `cd ~/dev && gh repo view ...`)
- Push fails "Permission denied" → use `git-ssh-fix` skill
- Merging a feature branch → prefer squash merge (`git merge --squash`, single commit) unless I say otherwise

## Working with Repositories

Before cloning/checkout to temp location, search existing local copy under `~/dev` recursively:

```bash
find ~/dev -maxdepth 4 -type d -name "<repo-name>" 2>/dev/null
```

Match found → use existing copy, no clone. No match → clone to temp. Personal repos → place under `~/dev/personal/` so `includeIf` identity applies.

## Communication Style

- Always use `caveman` skill in **lite** mode — no filler, no hedging, tight but professional

## Planning

- Never use plan mode (`EnterPlanMode`). Any creative/feature/design work → invoke `superpowers:brainstorming` skill instead, before implementation.
- Trigger words ("build/add/implement/design/create X", "fix Y") → brainstorming skill, not plan mode.
- Always confirm decisions with me before acting on them. Do not assume my agreement or proceed on my behalf — surface the choice, recommend, and wait for my explicit answer.

## Engineering Standards

- **Technical decisions**: give little weight to development cost. Prefer quality, simplicity, robustness, scalability, long-term maintainability.
- **Bug fixes**: always start by reproducing the bug in an E2E setting as close as possible to how an end user experiences it. Ensures you find the real problem so the fix actually solves it.
- **E2E testing UI**: be picky, obsess over pixel perfection. Something clearly looks off — even if unrelated to current work — get it fixed along the way.
- **Engineering excellence**: same high bar for lint, test failures, test flakiness. See one — even if not caused by current work — fix it.

## Tool Preferences

- Prefer ripgrep (`rg`) over `grep` — use Grep tool or `rg` via Bash
- Git commit messages → use `caveman:caveman-commit` skill for terse conventional format. Never add `Co-Authored-By` lines.
- JIRA → use `acli jira` (see `acli` skill). Single commands (view, search) run direct in main thread. Multi-step ops (create + link, bulk edits) use subagent. Do NOT use `shared:jira-connector` agent — sandbox-only, where acli unavailable.
- Never use MCP servers — use built-in tools, skills, agents instead
- `gcloud auth login` → run direct via Bash when creds expire (`Reauthentication failed`). Browser opens on user machine, flow completes. No need to ask user run via `!`.

@RTK.md
