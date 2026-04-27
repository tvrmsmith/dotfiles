# CLAUDE.md

Personal dotfiles managed with GNU Stow.

## Stow convention

Files/dirs prefixed `dot-` are symlinked into `$HOME` with the prefix replaced by `.` (via `stow --dotfiles`). Exclusions live in `.stow-local-ignore`. Submodules in `.gitmodules`.

## Workflow

- Install / add new files: `./install.sh` (or `stow --dotfiles -t "$HOME" .`)
- Edit existing `dot-*` file → change is live via symlink; no reinstall needed
- New top-level config → create as `dot-<name>` (or under `dot-config/`), then re-stow

## Notes

- Shell configs source `$CONSOLO_DOCKER_DEV_DIR/.helpers/{compose,git,system}.sh` — work-machine path, may not exist elsewhere; guard new sources similarly
- `NVIM_APPNAME` (set in `dot-zshenv`) selects the active neovim config: `nvim-LazyVim` (default), `nvim` (kickstart), or `nvim-Lazyman`. `nvims` command (Lazyman) switches interactively
- Agent sandboxing (`dsbx-*`, `nono-*`, files under `dot-agent-sandboxing/` or `dot-claude/sandbox/`): see the repo-scoped `agent-sandboxing` skill at `.claude/skills/agent-sandboxing/SKILL.md`.
