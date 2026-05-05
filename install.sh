#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install_gnu_stow() {
	# Install GNU Stow using whatever package manager is available

	# Check if stow is already installed
	if command -v stow >/dev/null 2>&1; then
		echo "GNU Stow is already installed."
		return
	fi

	if command -v brew >/dev/null 2>&1; then
		echo "Installing Stow using Homebrew..."
		brew install stow
	elif command -v apt >/dev/null 2>&1; then
		echo "Installing Stow using apt..."
		sudo apt update
		sudo apt install -y stow
	elif command -v dnf >/dev/null 2>&1; then
		echo "Installing Stow using dnf..."
		sudo dnf install -y stow
	elif command -v pacman >/dev/null 2>&1; then
		echo "Installing Stow using pacman..."
		sudo pacman -Syu --noconfirm stow
	elif command -v yum >/dev/null 2>&1; then
		echo "Installing Stow using yum..."
		sudo yum install -y stow
	else
		echo "No supported package manager found."
		echo "Please install GNU Stow manually."
		echo "Supported package managers: brew, apt, dnf, pacman, yum"
		exit 1
	fi

	echo "GNU Stow installation attempt complete."
}

init_submodules() {
	# Initialize and update git submodules with shallow cloning
	if [ -f "$SCRIPT_DIR/.gitmodules" ]; then
		echo "Initializing git submodules with shallow cloning..."
		git -C "$SCRIPT_DIR" submodule update --init --recursive --depth 1
		echo "Submodules initialized."
	fi
}

update_vendored_skills() {
	# Refresh subtree-vendored content (e.g. third-party Claude skills).
	# vendor/update is idempotent — no-op when subtrees are already current.
	if [ -x "$SCRIPT_DIR/vendor/update" ]; then
		echo "Updating vendored subtrees..."
		"$SCRIPT_DIR/vendor/update"
		echo "Vendored subtrees up to date."
	fi
}

setup_dotfiles() {
	# ~/.warp must exist as a real directory before stow runs: Warp writes
	# runtime data into it (worktrees/, typescript-language-server/, generated
	# tab configs). If ~/.warp didn't exist, stow would fold ~/.warp ->
	# dot-warp/ and route those runtime writes into this repo. Pre-creating
	# the writeable subdirs forces per-file linking; themes/ is left absent
	# so stow folds it (it's a read-only submodule).
	mkdir -p "$HOME/.warp/tab_configs" "$HOME/.warp/default_tab_configs"

	stow --dotfiles -d "$SCRIPT_DIR" -t "$HOME" .
}

install_gnu_stow
init_submodules
update_vendored_skills
setup_dotfiles
echo "Dot files installed."
