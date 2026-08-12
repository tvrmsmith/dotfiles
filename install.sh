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

export_corporate_ca() {
	# Must run before anything that talks to a registry: on a TLS-intercepting
	# corporate network Node rejects every fetch with SELF_SIGNED_CERT_IN_CHAIN and
	# npm retries silently for minutes before failing. .zshenv exports this for
	# normal shells; install.sh has to set it for its own npm calls. See dotfiles-3x1.
	local bundle
	bundle=$("$SCRIPT_DIR/dot-local/bin/corporate-ca-bundle" --path)
	"$SCRIPT_DIR/dot-local/bin/corporate-ca-bundle" || return 0
	[ -s "$bundle" ] && export NODE_EXTRA_CA_CERTS="$bundle"
}

install_pinned_npm_tools() {
	# Pinned global npm tools invoked by Claude Code hooks. Pinned (not `npx -y`)
	# so a later malicious publish is not auto-adopted, and the hook calls the
	# local binary offline instead of hitting the registry on every session.
	if ! command -v npm >/dev/null 2>&1; then
		echo "npm not found; skipping pinned npm tools (lavish-axi)."
		return
	fi
	local want="0.1.45"
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

install_tuicr() {
	# tuicr: Rust code-review TUI backing the vendored /tuicr skill (see
	# vendor/tuicr). Install-if-missing (idempotent); upgrade with `tuicr update`.
	if command -v tuicr >/dev/null 2>&1; then
		echo "tuicr already installed ($(tuicr --version 2>/dev/null))."
		return
	fi
	if command -v brew >/dev/null 2>&1; then
		echo "Installing tuicr using Homebrew..."
		brew install agavra/tap/tuicr
	elif command -v curl >/dev/null 2>&1; then
		echo "Installing tuicr..."
		curl -fsSL https://tuicr.dev/install.sh | sh
	else
		echo "Neither brew nor curl found; skipping tuicr install."
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

	# ~/.agents must likewise exist as a real directory. Left absent, stow folds
	# ~/.agents -> dot-agents/, and stow 2.4.1 --dotfiles then re-appends the
	# translated name when it later needs to unfold, looking for a nonexistent
	# dot-agents/.agents and aborting the entire install.
	mkdir -p "$HOME/.agents"

	# ~/.config for the same reason, and this one has teeth: corporate-ca-bundle
	# writes the trust bundle to $XDG_CONFIG_HOME/corporate-ca.crt. Folded, that
	# write lands in dot-config/ — the machine's corporate CAs committed into a
	# public repo. export_corporate_ca runs before stow and mkdir -p's the
	# directory itself, so today this is belt-and-braces; it stops being that the
	# moment those calls are reordered. .gitignore covers the same case at the
	# other end.
	mkdir -p "$HOME/.config"

	# dot-claude/settings.json is stowed like everything else. It used to be
	# excluded and regenerated per machine, because it carried work-only config
	# (Vertex creds, WellSky OTEL endpoint) that breaks Claude Code on personal
	# machines, and Claude Code has no include mechanism to vary one file by
	# machine. Those keys now live in ~/.zshenv.local (untracked, sourced from
	# .zshenv), leaving the tracked file machine-neutral. Symlinking it also
	# means Claude Code's own writes — plugin toggles, effortLevel, marketplace
	# entries — land in the repo instead of silently drifting from it.
	#
	# That link does not hold on its own: writers that save the file atomically
	# (temp file + rename) replace it with a regular file, and `claude doctor`
	# is one of them. dot-claude/hooks/relink-settings.sh runs at SessionStart
	# and restores the link, adopting whatever the live file accumulated first.
	#
	# Stow only owns links written relative to the package, so a link restored
	# any other way reads as a foreign target and aborts the whole install
	# before anything is placed. Drop any link that already points at our own
	# copy and let stow lay it down again.
	claude_settings="$HOME/.claude/settings.json"
	if [ -L "$claude_settings" ] &&
		[ "$(readlink -f "$claude_settings")" = "$(readlink -f "$SCRIPT_DIR/dot-claude/settings.json")" ]; then
		rm -f "$claude_settings"
	fi

	stow --dotfiles -d "$SCRIPT_DIR" -t "$HOME" .

	# The one entry stow can't place (see .stow-local-ignore): it's a symlink to
	# a directory, which stow 2.4.1 --dotfiles tries to descend into.
	ln -sfn "$SCRIPT_DIR/dot-claude/skills" "$HOME/.agents/skills"
}

export_corporate_ca
install_gnu_stow
init_submodules
update_vendored_skills
install_pinned_npm_tools
install_no_mistakes
install_tuicr
setup_dotfiles
echo "Dot files installed."
