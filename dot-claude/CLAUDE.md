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
- Spec and plan reviews → present via `lavish` skill (rich reviewable HTML artifact) by default

## Planning

- **Vertical slice**: an item of work cutting a narrow but COMPLETE path through every layer (UI → API → domain → data, plus tests) that independently works end-to-end. Not a horizontal layer ("all the endpoints") nor a partial stub.
- Never use plan mode (`EnterPlanMode`). Any creative/feature/design work → reach for Matt Pocock's skills (e.g. `/wayfinder`, `/grill-with-docs`) instead, before implementation.
- Confirm decisions with me before acting: surface the choice, recommend, wait for my explicit answer.

## Delegating to agents

- When kicking off a subagent or other agent (Agent tool, orca, etc.), don't inline context it already inherits or can discover: memory/instruction files (`CLAUDE.md`, `CLAUDE.local.md`, skills) or ticket content (bd/JIRA description, design/spec field). Point to it — "implement bead `<id>`, spec in its `design` field" — and let the agent read it.
- Pass only the non-discoverable: the task, decisions/constraints not in the ticket, and pointers. Duplication just clutters the agent's window.

## Engineering Standards

- **Technical decisions**: estimate effort at agent speed, not human-team scale — then let quality, simplicity, robustness, maintainability decide, not cost.
- **Bug fixes**: always start by reproducing the bug in an E2E setting as close as possible to how an end user experiences it. Ensures you find the real problem so the fix actually solves it.
- **Boy-scout rule**: see something off — pixel glitch, lint warning, test flake — even outside current scope, fix it along the way. Obsess over pixel perfection in UI.
- **Coding standards**: ALWAYS load the `coding-standards` skill before writing, modifying, or reviewing code, and follow it.
- **Cross-boundary contract approval**: any contract crossing a service or independent-deploy boundary (service↔service, frontend↔BFF, Kafka/event schemas, APIs consumed outside the owning service) needs my approval before implementation — load the `contract-approval` skill and follow it. Internal seams you change within one PR don't need approval.

## Tool Preferences

- Prefer ripgrep (`rg`) over `grep` — use Grep tool or `rg` via Bash
- Git commit messages → use `caveman:caveman-commit` skill for terse conventional format. Never add `Co-Authored-By` lines.
- JIRA → use `acli jira` (see `acli` skill). Single commands (view, search) run direct in main thread. Multi-step ops (create + link, bulk edits) use subagent. Do NOT use `shared:jira-connector` agent — sandbox-only, where acli unavailable.
- Never use MCP servers — use built-in tools, skills, agents instead
- `gcloud auth login` → run direct via Bash when creds expire (`Reauthentication failed`). Browser opens on user machine, flow completes. No need to ask user run via `!`.
