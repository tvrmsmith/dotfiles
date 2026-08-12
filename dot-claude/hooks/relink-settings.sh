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

command -v python3 >/dev/null 2>&1 || exit 0

# The link has to be relative, exactly as stow writes it. An absolute one
# resolves to the same file and Claude Code never notices, but stow does not
# recognise it as its own and aborts the next install before linking anything.
link_target=$(python3 -c \
	'import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' \
	"$REPO_SETTINGS" "$LIVE_SETTINGS") || exit 0

# Adopt only a live file that still holds every top-level key the tracked copy
# has. Parsing as JSON is not enough: when install.sh drops the link and stow
# aborts, Claude Code writes a fresh single-key file that parses perfectly, and
# copying that over the repo erases plugins, permissions and marketplaces. A
# subset means the live file was rebuilt from nothing, not written to - keep the
# tracked copy and park the stub for inspection.
if python3 - "$LIVE_SETTINGS" "$REPO_SETTINGS" <<'PY'
import json, sys
try:
	live = json.load(open(sys.argv[1]))
	repo = json.load(open(sys.argv[2]))
except Exception:
	sys.exit(1)
sys.exit(0 if isinstance(live, dict) and isinstance(repo, dict)
		 and not set(repo) - set(live) else 1)
PY
then
	cp "$LIVE_SETTINGS" "$REPO_SETTINGS" || exit 0
else
	cp "$LIVE_SETTINGS" "$LIVE_SETTINGS.rejected" 2>/dev/null
fi

ln -sfn "$link_target" "$LIVE_SETTINGS"

exit 0
