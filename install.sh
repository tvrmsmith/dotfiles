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

setup_dotfiles() {
	stow --dotfiles --adopt -d "$SCRIPT_DIR" -t "$HOME" .
}

install_gnu_stow
init_submodules
setup_dotfiles
echo "Dot files installed."
