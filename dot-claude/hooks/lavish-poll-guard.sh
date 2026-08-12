#!/bin/bash
# lavish-poll-guard.sh — Claude Code PreToolUse (Bash) guard.
#
# `lavish-axi poll` long-polls until a human finishes reviewing the artifact, which
# routinely outruns the Bash tool's 600s foreground ceiling: the call is killed
# mid-wait, and the agent either burns turns re-running it or abandons the review
# and answers in the main thread. Claude Code's tracked background jobs re-invoke
# the agent when the poll exits, so they satisfy Lavish's verified-wake-path rule
# and carry no time limit.
#
# The poll passes when run_in_background is true. Shell-level detachment (nohup,
# disown, trailing &) leaves the harness with nothing to wake, so it is blocked
# even though the process would survive — Lavish's SKILL.md bans it for the same
# reason.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -n "$CMD" ] || exit 0

# Anchored to a command position (start, or after ; & | && || ) so that echoing,
# grepping, or documenting the string is not mistaken for running it.
printf '%s' "$CMD" \
  | grep -Eq '(^|[;&|(])[[:space:]]*(nohup[[:space:]]+)?lavish-axi[[:space:]]+poll([[:space:]]|$)' \
  || exit 0

BACKGROUND=$(printf '%s' "$INPUT" | jq -r '.tool_input.run_in_background // false')

DETACHED=0
if printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])(nohup|disown)([[:space:]]|$)|&[[:space:]]*$'; then
  DETACHED=1
fi

if [ "$BACKGROUND" = "true" ] && [ "$DETACHED" = 0 ]; then
  exit 0
fi

if [ "$DETACHED" = 1 ]; then
  REASON='lavish-axi poll blocked — shell detachment (nohup/disown/&) runs the poll outside the harness, so nothing wakes you when feedback arrives.

Run the plain command with the Bash tool'"'"'s run_in_background: true instead. That is a tracked job: Claude Code re-invokes you with the poll output when the user sends feedback.'
else
  REASON='lavish-axi poll blocked — a foreground poll dies at the Bash tool'"'"'s 600s ceiling, and human review takes longer than ten minutes.

Re-run this exact command with run_in_background: true. Claude Code tracks the job and re-invokes you with the feedback whenever the user sends it, with no time limit. Queued feedback is never lost.'
fi

jq -n --arg r "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
