#!/usr/bin/env bash
# t3code Claude binary wrapper — routes t3code's Claude sessions through claude-launcher.
# Set as t3code Settings -> Claude -> "Binary path".
#
# Vertex backend is NOT set here: ~/.claude/settings.json's `env` block configures it,
# and Claude Code applies its own settings.json env at startup. Only set Vertex vars here
# if you point t3code at a custom Claude HOME path whose settings.json lacks that block.
#
# t3code appends --dangerously-skip-permissions itself, so this wrapper does not.
set -euo pipefail

exec "$HOME/.local/bin/claude-launcher" "$@"
