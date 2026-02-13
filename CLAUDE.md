# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a personal dotfiles repository that manages shell configurations, application settings, and development environment setup using GNU Stow. The repository uses a `dot-` prefix naming convention where files/directories are symlinked to the home directory with the prefix replaced by a dot.

## Installation & Setup

**Install dotfiles:**

```bash
./install.sh
```

This script:

1. Installs GNU Stow if not present
2. Runs `stow --dotfiles -t "$HOME" .` to symlink all `dot-*` files to `~/.`

**Manual stow:**

```bash
stow --dotfiles -t "$HOME" .
```

## Repository Structure

### Shell Configuration

- `dot-zshenv` - Environment variables (XDG paths, mise, NVM, editor settings)
- `dot-zshrc` - Zsh interactive config (zinit plugin manager, starship prompt, aliases)
- `dot-bashrc` - Bash interactive config (similar structure to zshrc)
- `dot-zprofile` - Zsh login shell configuration
- `dot-gitconfig` - Git configuration with delta pager and neovim diff tool

### Application Configs (`dot-config/`)

Configuration directories for various tools:

- `nvim/`, `nvim-LazyVim/`, `nvim-Lazyman/` - Neovim configurations (git submodules)
- `aerospace/` - Window manager configuration
- `ghostty/` - Terminal emulator settings
- `eza/` - File listing tool with custom theme
- `lazygit/` - Git TUI configuration
- `mise/` - Development environment manager
- `gh/` - GitHub CLI settings
- `helix/`, `tree-sitter/`, `git/`, `1Password/`, etc.

### Git Submodules

The repository contains several submodules:

- `dot-config/nvim` - Custom kickstart.nvim config
- `dot-config/nvim-LazyVim` - LazyVim configuration
- `dot-config/nvim-Lazyman` - Lazyman nvim distribution
- `dot-warp/themes` - Warp terminal themes
- `bat-into-tokyonight` - Bat theme generator

### Stow Ignore File

The `.stow-local-ignore` file controls which files are excluded from symlinking:

- Repository metadata: `CLAUDE.md`, `README.md`, `LICENSE`
- Installation scripts: `install.sh`
- Version control files: `.git`, `.gitignore`, `.gitmodules`
- Editor/IDE directories: `.idea`, `.vscode`

Only files with the `dot-` prefix (and not in the ignore list) are symlinked to the home directory.

## Key Environment Variables

From `dot-zshenv`:

- `NVIM_APPNAME="nvim-LazyVim"` - Default neovim config
- `EDITOR="vim"`, `VISUAL="nvim"`
- XDG Base Directory spec: `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`
- Bat themes: `BAT_THEME_DARK="tokyonight_night"`, `BAT_THEME_LIGHT="tokyonight_day"`

## Important Shell Integrations

The shell configs source external helpers from a work repository:

```bash
source $CONSOLO_DOCKER_DEV_DIR/.helpers/{compose,git,system}.sh
```

These paths reference `/Users/trevor.smith/dev/wellsky/consolo.docker-dev/` and may not exist in all environments.

## Tooling Stack

**Shell:**

- zinit - Plugin manager for zsh
- starship - Cross-shell prompt
- mise - Runtime version manager (replaces asdf)
- zoxide - Smarter cd command

**Git:**

- delta - Syntax-highlighting pager
- lazygit - Terminal UI for git
- nvim as difftool

**CLI Tools:**

- eza - Modern ls replacement with custom theme
- bat - cat with syntax highlighting
- just - Command runner (completion enabled)

## Neovim Configuration

Multiple neovim configs are available via `NVIM_APPNAME`:

- Default: `nvim-LazyVim`
- Also available: `nvim` (kickstart), `nvim-Lazyman`

The Lazyman config provides `nvims` command for switching between configurations.

## Modifying Configurations

When editing dotfiles:

1. Edit files in this repository with `dot-` prefix
2. Changes propagate to home directory via stow symlinks
3. No need to re-run install unless adding new files

When adding new config directories:

- Create as `dot-<name>` in repository root or under `dot-config/`
- Run `stow --dotfiles -t "$HOME" .` to create symlinks
