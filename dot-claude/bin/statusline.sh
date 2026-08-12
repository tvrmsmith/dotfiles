#!/bin/bash
# statusline.sh - render the status line and hand the same payload to Orca.
#
# Claude Code allows one statusLine command. Orca's agent hook wants the JSON
# payload for the rate-limit display in its own pane chrome, and claims it by
# overwriting statusLine outright - which is how claude-powerline was lost on
# 2026-08-11. Fan the payload out to both. The Orca hook writes nothing to
# stdout, so only powerline reaches the status line.

set -u

ORCA_STATUSLINE="$HOME/.orca/agent-hooks/claude-statusline.sh"

payload=$(cat)

# Absent outside an Orca pane, and inert without its port/token env anyway.
if [ -x "$ORCA_STATUSLINE" ]; then
	printf '%s' "$payload" | /bin/sh "$ORCA_STATUSLINE" >/dev/null 2>&1 || :
fi

printf '%s' "$payload" | mise exec node@25 -- claude-powerline --theme=tokyo-night --style=powerline
