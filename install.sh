#!/bin/bash

install_gnu_stow() {
  # Update package lists and install GNU Stow based on the detected distribution.

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
  elif type lsb_release >/dev/null 2>&1; then
    OS=$(lsb_release -si)
  else
    OS=$(uname -s)
  fi

  echo "Detected OS: $OS"

  case "$OS" in
  "Ubuntu" | "Debian GNU/Linux" | "Linux Mint")
    echo "Installing Stow using apt..."
    sudo apt update
    sudo apt install -y stow
    ;;
  "Fedora" | "CentOS Linux" | "Red Hat Enterprise Linux" | "Rocky Linux" | "AlmaLinux")
    echo "Installing Stow using dnf..."
    sudo dnf install -y stow
    ;;
  "Arch Linux")
    echo "Installing Stow using pacman..."
    sudo pacman -Syu --noconfirm stow
    ;;
  "macOS")
    echo "Installing Stow using Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    brew install stow
    ;;
  *)
    echo "Unsupported operating system. Please install GNU Stow manually."
    echo "Refer to your distribution's documentation for instructions."
    exit 1
    ;;
  esac

  echo "GNU Stow installation attempt complete."
}

setup_dotfiles() {
  stow --dotfiles -t "$HOME"
}

install_gnu_stow
setup_dotfiles
echo "Dot files installed."
