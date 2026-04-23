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
- Agent sandboxing lives in `dot-agent-sandboxing` (sourced by shell rc) and `dot-claude/sandbox/` (Dockerfiles + compose). Two stacks: `nono-*` ([nsjail-based](https://nono.sh/docs/)) and `dsbx-*` ([Docker `sbx`](https://docs.docker.com/ai/sandboxes/)). `sbx` runs microVMs in an embedded containerd — host `docker ps`/`exec`/`logs` won't see them; use `sbx ls`/`exec`/`run`, or `docker -H unix://$_DSBX_SBXD_SOCK ...` for the inner daemon. Edit those files directly — do not duplicate aliases/helpers elsewhere
