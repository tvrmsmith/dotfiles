#!/bin/bash
# relink-settings.sh - restore ~/.claude/settings.json as a stow symlink
#
# install.sh stows dot-claude/settings.json so Claude Code's own writes (plugin
# toggles, effortLevel, marketplace entries) land in the repo instead of
# drifting from it. Some writers - `claude doctor` is the confirmed one - write
# the file atomically (temp file + rename), which replaces the symlink with a
# regular file and silently ends that arrangement.
#
# Runs at SessionStart. When the link is gone, the live file is authoritative:
# it holds every write made since the break. Copy it back over the repo copy,
# then re-link. Silent and idempotent; never fails a session start.

set -u

DOTFILES="${DOTFILES_DIR:-$HOME/dev/personal/dotfiles}"
REPO_SETTINGS="$DOTFILES/dot-claude/settings.json"
LIVE_SETTINGS="$HOME/.claude/settings.json"

# Already linked, or this machine has no dotfiles checkout: nothing to do.
[ -L "$LIVE_SETTINGS" ] && exit 0
[ -f "$REPO_SETTINGS" ] || exit 0
[ -f "$LIVE_SETTINGS" ] || exit 0

# Only adopt live content that parses - a truncated or half-written file must
# not overwrite the tracked copy.
command -v python3 >/dev/null 2>&1 || exit 0
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$LIVE_SETTINGS" 2>/dev/null || exit 0

# The link has to be relative, exactly as stow writes it. An absolute one
# resolves to the same file and Claude Code never notices, but stow does not
# recognise it as its own and aborts the next install before linking anything.
link_target=$(python3 -c \
	'import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' \
	"$REPO_SETTINGS" "$LIVE_SETTINGS") || exit 0

cp "$LIVE_SETTINGS" "$REPO_SETTINGS" || exit 0
ln -sfn "$link_target" "$LIVE_SETTINGS"

exit 0
