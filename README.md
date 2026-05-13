# dotfiles

Personal dotfiles managed with [GNU Stow](https://www.gnu.org/software/stow/).

## Install

```sh
git clone git@github-personal:tvrmsmith/dotfiles.git ~/dev/personal/dotfiles
cd ~/dev/personal/dotfiles
./install.sh  # or: stow --dotfiles -t "$HOME" .
```

Files and directories prefixed with `dot-` are symlinked into `$HOME` with the prefix replaced by `.` (e.g. `dot-zshrc` becomes `~/.zshrc`).

## What's included

| Category | Configs |
|----------|---------|
| Shell | zsh (`dot-zshrc`, `dot-zshenv`, `dot-zprofile`), bash (`dot-bashrc`) |
| Git | `dot-gitconfig`, `dot-gitconfig-personal` |
| Terminal | Ghostty, iTerm2, Warp |
| Editor | Neovim (LazyVim, Kickstart, Lazyman), Helix |
| Window mgmt | AeroSpace |
| Tools | mise, lazygit, eza, starship, kanata, bat, tree-sitter |
| AI/Agents | Claude Code (`dot-claude`), agent sandboxing (`dot-agent-sandboxing`) |
| SSH | 1Password agent, GitHub host aliases |
| Node | `.npmrc`, `.bunfig.toml`, `default-npm-packages` |

## Extras

Non-stowed files in `extras/` — manually applied configs for apps that don't read from dotfiles.

### Vimium C — Tokyo Night theme

Custom CSS theme for [Vimium C](https://github.com/gdh1995/vimium-c) based on the [Tokyo Night](https://github.com/tokyo-night/tokyo-night-vscode-theme) Night variant.

**Apply:** Copy contents of `extras/vimium-c-tokyo-night.css` and paste into Vimium C Options → Custom CSS.

## Neovim

Multiple configs available, selected via `NVIM_APPNAME` (set in `dot-zshenv`):

- `nvim-LazyVim` — primary config (default)
- `nvim` — kickstart-based
- `nvim-Lazyman` — Lazyman

Switch interactively with the `nvims` command.
