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
	#
	# Installed through mise's npm backend, not `npm install -g`: mise scopes
	# global npm packages to the active node version, so a subagent, sandbox, or
	# repo resolving a different node loses the binary entirely ("No version is
	# set for shim: lavish-axi"). The npm: tool is pinned in dot-config/mise/
	# config.toml and resolves under any node.
	local want="0.1.50"
	if lavish-axi --version 2>/dev/null | grep -q "$want"; then
		echo "lavish-axi@$want already installed."
		return
	fi
	if command -v mise >/dev/null 2>&1; then
		echo "Installing lavish-axi@$want via mise..."
		mise install "npm:lavish-axi@$want"
	elif command -v npm >/dev/null 2>&1; then
		echo "mise not found; installing lavish-axi@$want with npm -g (node-version scoped)..."
		npm install -g "lavish-axi@$want"
	else
		echo "neither mise nor npm found; skipping pinned npm tools (lavish-axi)."
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

# Files that live-writers replace instead of updating in place. Each is stowed
# like everything else, but a writer that saves atomically (temp file + rename)
# swaps our symlink for a regular file, and stow then refuses to place anything
# at all:
#
#   dot-claude/settings.json     `claude doctor` and Claude Code's own writes
#                                (plugin toggles, effortLevel, marketplace
#                                entries)
#   dot-config/gh/hosts.yml      `gh auth switch` / `gh auth login`
#   dot-config/1Password/telemetry-enabled   the 1Password desktop app
LIVE_WRITER_FILES=(
	dot-claude/settings.json
	dot-config/gh/hosts.yml
	dot-config/1Password/telemetry-enabled
)

live_target() {
	# The $HOME path stow places a dot- prefixed repo path at.
	printf '%s\n' "$HOME/.${1#dot-}"
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

	# Reconcile the live-writer files (see LIVE_WRITER_FILES) before stow: drop
	# the live copy when it's already a link to our file, or a regular file
	# byte-identical to it. Anything with real drift is left alone so stow
	# reports the conflict and a human decides.
	reconciled=()
	for rel in "${LIVE_WRITER_FILES[@]}"; do
		src="$SCRIPT_DIR/$rel"
		target=$(live_target "$rel")
		[ -e "$src" ] || continue
		# Stow folds an absent ~/.claude into one symlink to dot-claude/, so on
		# the next run $target reaches $src itself through that folded parent.
		# It then reads as a regular file, byte-identical to itself, and the rm
		# below would delete the repo's own copy. -ef compares device and inode.
		[ "$target" -ef "$src" ] && continue
		if [ -L "$target" ]; then
			[ "$(readlink -f "$target")" = "$(readlink -f "$src")" ] || continue
		elif [ -f "$target" ]; then
			cmp -s "$target" "$src" || continue
		else
			continue
		fi
		rm -f "$target"
		reconciled+=("$rel")
	done

	# An aborted stow places nothing, so every target dropped just above stays
	# gone and its writer recreates a fresh stub — e.g. Claude Code writes
	# settings.json anew and the SessionStart relink hook adopts that stub over
	# the tracked copy. Put the links back and stop, rather than leaving the
	# window open. Content was identical, so a link is the same file either way.
	if ! stow --dotfiles -d "$SCRIPT_DIR" -t "$HOME" .; then
		for rel in "${reconciled[@]}"; do
			src="$SCRIPT_DIR/$rel"
			target=$(live_target "$rel")
			restore_link="$src"
			if command -v python3 >/dev/null 2>&1; then
				# Stow only recognises links spelled relative to the package.
				restore_link=$(python3 -c \
					'import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' \
					"$src" "$target") || restore_link="$src"
			fi
			ln -sfn "$restore_link" "$target" ||
				echo "install.sh: could not restore $target -> $restore_link; recreate it by hand before the writer does." >&2
		done
		echo "install.sh: stow aborted; resolve the conflicts above and re-run." >&2
		exit 1
	fi

	# The one entry stow can't place (see .stow-local-ignore): it's a symlink to
	# a directory, which stow 2.4.1 --dotfiles tries to descend into.
	ln -sfn "$SCRIPT_DIR/dot-claude/skills" "$HOME/.agents/skills"
}

main() {
	export_corporate_ca
	install_gnu_stow
	init_submodules
	update_vendored_skills
	install_pinned_npm_tools
	install_no_mistakes
	install_tuicr
	setup_dotfiles
	echo "Dot files installed."
}

# Sourcing this file defines the functions without installing anything, so the
# bats suite can drive setup_dotfiles against a scratch SCRIPT_DIR and HOME.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main
fi
