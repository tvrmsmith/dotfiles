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

install_pinned_npm_tools() {
	# Pinned global npm tools invoked by Claude Code hooks. Pinned (not `npx -y`)
	# so a later malicious publish is not auto-adopted, and the hook calls the
	# local binary offline instead of hitting the registry on every session.
	if ! command -v npm >/dev/null 2>&1; then
		echo "npm not found; skipping pinned npm tools (lavish-axi)."
		return
	fi
	local want="0.1.38"
	if lavish-axi --version 2>/dev/null | grep -q "$want"; then
		echo "lavish-axi@$want already installed."
	else
		echo "Installing lavish-axi@$want..."
		npm install -g "lavish-axi@$want"
	fi
}

install_no_mistakes() {
	# no-mistakes: Go CLI backing the vendored /no-mistakes skill (see
	# vendor/no-mistakes). Installs to ~/.no-mistakes/bin and symlinks into
	# ~/.local/bin. Upstream install.sh has no version-pin env var, so this is
	# install-if-missing (idempotent); re-run manually to upgrade.
	if command -v no-mistakes >/dev/null 2>&1; then
		echo "no-mistakes already installed ($(no-mistakes --version 2>/dev/null))."
		return
	fi
	if ! command -v curl >/dev/null 2>&1; then
		echo "curl not found; skipping no-mistakes install."
		return
	fi
	echo "Installing no-mistakes..."
	curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh
}

claude_machine_profile() {
	# dot-claude/settings.json carries work-only config (Google Vertex creds,
	# WellSky OTEL endpoint) that breaks Claude Code on personal machines
	# (invalid Vertex credentials). Claude Code has no include mechanism for
	# settings.json, so a straight symlink can't vary by machine. Cache the
	# answer in a plain (non-stowed) marker file so re-running install.sh
	# doesn't re-prompt.
	local marker="$HOME/.claude-profile"
	if [ -f "$marker" ]; then
		cat "$marker"
		return
	fi
	if [ ! -t 0 ]; then
		echo "work"
		return
	fi
	local answer
	read -r -p "Is this a work or personal machine? [work/personal]: " answer </dev/tty
	case "$answer" in
	personal) echo "personal" ;;
	*) echo "work" ;;
	esac >"$marker"
	cat "$marker"
}

setup_dotfiles() {
	# ~/.warp must exist as a real directory before stow runs: Warp writes
	# runtime data into it (worktrees/, typescript-language-server/, generated
	# tab configs). If ~/.warp didn't exist, stow would fold ~/.warp ->
	# dot-warp/ and route those runtime writes into this repo. Pre-creating
	# the writeable subdirs forces per-file linking; themes/ is left absent
	# so stow folds it (it's a read-only submodule).
	mkdir -p "$HOME/.warp/tab_configs" "$HOME/.warp/default_tab_configs"

	local profile
	profile="$(claude_machine_profile)"

	if [ "$profile" = "personal" ]; then
		# Stow everything except dot-claude/settings.json — that one gets a
		# real, machine-local file below instead of a symlink, so Vertex vars
		# stripped here don't get written back to the tracked repo file.
		stow --dotfiles -d "$SCRIPT_DIR" -t "$HOME" --ignore='settings\.json' .
		rm -f "$HOME/.claude/settings.json"
		if command -v jq >/dev/null 2>&1; then
			jq 'del(.env.CLAUDE_CODE_USE_VERTEX, .env.ANTHROPIC_VERTEX_PROJECT_ID, .env.CLOUD_ML_REGION)' \
				"$SCRIPT_DIR/dot-claude/settings.json" >"$HOME/.claude/settings.json"
			echo "Personal machine: wrote ~/.claude/settings.json with Vertex vars stripped (real file, not symlinked)."
		else
			cp "$SCRIPT_DIR/dot-claude/settings.json" "$HOME/.claude/settings.json"
			echo "jq not found; copied settings.json as-is. Remove CLAUDE_CODE_USE_VERTEX, ANTHROPIC_VERTEX_PROJECT_ID, CLOUD_ML_REGION from ~/.claude/settings.json manually."
		fi
	else
		stow --dotfiles -d "$SCRIPT_DIR" -t "$HOME" .
	fi
}

install_gnu_stow
init_submodules
update_vendored_skills
install_pinned_npm_tools
install_no_mistakes
setup_dotfiles
echo "Dot files installed."
