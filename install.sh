#!/bin/bash

install_gnu_stow() {
	# Install GNU Stow using whatever package manager is available

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
	if [ -f .gitmodules ]; then
		echo "Initializing git submodules with shallow cloning..."
		git submodule update --init --recursive --depth 1
		echo "Submodules initialized."
	fi
}

setup_dotfiles() {
	stow --dotfiles --adopt -t "$HOME" .
}

install_gnu_stow
init_submodules
setup_dotfiles
echo "Dot files installed."
