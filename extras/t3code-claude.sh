#!/usr/bin/env bash
# t3code Claude binary wrapper — applies the skillOverrides patch, then execs claude.
# Set as t3code Settings -> Claude -> "Binary path".
#
# Vertex backend is NOT set here: ~/.claude/settings.json's `env` block configures it,
# and Claude Code applies its own settings.json env at startup. Only set Vertex vars here
# if you point t3code at a custom Claude HOME path whose settings.json lacks that block.
#
# t3code appends --dangerously-skip-permissions itself, so this wrapper does not.
set -euo pipefail

# Apply binary patch (idempotent; early-exits when already patched). Re-runs each launch
# so it self-heals after a Claude Code update changes the version binary.
"$HOME/dev/personal/dotfiles/extras/claude-code-patch.sh" >/dev/null 2>&1 || true

# Hand off to the real launcher with t3code's args.
exec "$HOME/.local/bin/claude" "$@"
