# Global Agent Instructions

- My name is Trevor, I'm a Staff Software Engineer for WellSky, a healthcare technology company. I'm a member of the Home Health business unit and the hospice squad within it.
- Laptop leaves network coverage, so network failures are transient. Retry, don't blame creds/remote/config.

## Repositories

- Personal repos under `~/dev/personal/` 
- Work repos elsewhere under `~/dev/` 
- Before cloning/checkout to temp location, search existing local copy under `~/dev` recursively.

## Git Configuration

- Write concise commit messages, keep them under 150 words
- `~/.gitconfig` uses `includeIf "gitdir:~/dev/personal/"` to auto-load `~/.gitconfig-personal`, sets personal `user.name`, `user.email` (`tvrmsmith@gmail.com`), personal SSH signing key
- Repos cloned under `~/dev/personal/` auto-get personal identity, no per-repo `git config` needed
- `GITHUB_TOKEN` from 1Password CLI plugin. Directory-aware:
  - **Outside `~/dev/personal/`**: auth as work account (`TrevorSmith-Wellsky`). Use `github.com` direct for remotes and `gh` commands
  - **Inside `~/dev/personal/`**: auth as personal account (`tvrmsmith`). Use `github-personal` SSH host alias for remotes, `gh auth switch --user tvrmsmith` before `gh` commands (PRs, issues, etc.)
- `gh` commands against work repos from inside `~/dev/personal/` → `cd` to non-personal directory first (e.g. `cd ~/dev && gh repo view ...`)
- Merging a feature branch → prefer squash merge

## Planning

- **Vertical slice**: an item of work cutting a narrow but COMPLETE path through every layer (UI → API → domain → data, plus tests) that independently works end-to-end. Not a horizontal layer ("all the endpoints") nor a partial stub.
- Reach for Matt Pocock's skills (e.g. `mattpocock-skills:wayfinder`, `mattpocock-skills:grill-with-docs`) before implementation

## Working with Agents

- **Agent-facing docs**: ALWAYS load the `mattpocock-skills:writing-for-agents` skill before writing, editing, or reviewing any document an agent consumes, and follow it. Covers a `SKILL.md`, `AGENTS.md`/`CLAUDE.md`, a subagent prompt, a hook's injected text, a doc reached by a pointer from one of those. Same rule when a skill isn't firing and you're diagnosing why.
- When kicking off a subagent or other agent (Agent tool, orca, etc.), don't inline context it already inherits or can discover: memory/instruction files (`CLAUDE.md`, `CLAUDE.local.md`, skills) or ticket content (bd/JIRA description, design/spec field). Point to it instead, as in "implement bead `<id>`, spec in its `design` field", and let the agent read it.
- Pass only the non-discoverable: the task, decisions/constraints not in the ticket, and pointers. Duplication just clutters the agent's window.
- **Explore subagent model rubric**. Pick the Explore subagent's model explicitly via the Agent tool `model` override:
  - **haiku**. Default for cheap locate work: "where is X", "what calls Y", "list uses of Z", map a small/familiar dir. Pure grep/glob/read, no judgment.
  - **sonnet**. When the search needs judgment: which of many files matter, tracing data flow across modules, unfamiliar/large codebase, or the answer depends on conventions the built-in can't see.
  - **opus**. Rare, only when the exploration itself requires hard reasoning, not just finding.
  - Under-exploration is the silent failure (incomplete answer that looks complete). When unsure between two tiers, pick the higher.

## Engineering Standards

- ALWAYS load the `engineering-principles` skill when planning, implementing, or verifying a change, and follow it.
- **Estimation**: estimate effort at agent speed, not human-team scale. Then let quality, simplicity, robustness, maintainability decide, not cost.
- **Bug fixes**: always start by reproducing the bug in an E2E setting as close as possible to how an end user experiences it. Ensures you find the real problem so the fix actually solves it.
- **Implementation phase**: ALWAYS load the `coding-standards:coding-standards` skill before writing or modifying code, and follow it.
- **Design phase**: ALWAYS load the `mattpocock-skills:codebase-design` skill before placing a seam, designing or changing a module interface, or restructuring code, and use its vocabulary.
- **Cross-boundary contract approval**: any contract crossing a service or independent-deploy boundary (service↔service, frontend↔BFF, Kafka/event schemas, APIs consumed outside the owning service) needs my approval before implementation. Load the `contract-approval` skill and follow it.

