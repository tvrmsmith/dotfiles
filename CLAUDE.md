# CLAUDE.md

Personal dotfiles managed with GNU Stow.

## Notes

Each of these is a rule the files themselves do not confess.

- Editing a stowed `dot-*` file is live through the symlink. Adding one needs `./install.sh`, run from the main checkout. Where the target directory already existed, stow links each file separately instead of folding the parent (`~/.local/bin` is a real directory of per-file links), so a new script has no link until stow runs again. A worktree cannot install its own: stow links from wherever `install.sh` sits, so a new `dot-local/bin` script is on `PATH` only after it merges
- `slice-pipeline/` is a self-contained subproject, not dotfiles. It is stow-ignored and carries its own test helpers and runner; `install.sh` links its script onto `PATH` and its workflow into Archon's global scope, because it is meant to run against any repo. See `slice-pipeline/README.md`
- A `~/.config` subdirectory whose own tool writes into it (`gh` rewrites `hosts.yml`, 1Password drops `telemetry-enabled`) needs BOTH a `mkdir -p` in `install.sh` and the runtime name in `.stow-local-ignore`. The mkdir is load-bearing, not belt-and-braces. With the target absent, stow folds the parent into one symlink and never descends, so a nested ignore pattern is never consulted
- Shell configs source `$CONSOLO_DOCKER_DEV_DIR/.helpers/{compose,git,system}.sh`, a work-machine path that is absent elsewhere. Guard a new source the same way
- `gh` runs through `dot-local/bin/gh`, which picks a credential tier from what the command does. The design and its traps are in that file's header comment; `GH_SHIM_EXPLAIN=1 gh <args>` prints the routing decision and runs nothing. Sourcing `~/.config/op/plugins.sh` after startup restores an alias that shadows the shim

## Issue tracker

Issues live in beads (`bd`). The Matt Pocock skills — `/wayfinder` above all — read
`docs/agents/issue-tracker.md` for how this repo expresses maps, child tickets, blocking, and
the frontier query.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
