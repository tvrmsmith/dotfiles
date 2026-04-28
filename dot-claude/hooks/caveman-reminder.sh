#!/usr/bin/env bash
# UserPromptSubmit hook — injects caveman-lite reminder per ~/.claude/CLAUDE.md.
# Output protocol: https://docs.claude.com/en/docs/claude-code/hooks
set -euo pipefail

REMINDER='Use skill://caveman:caveman lite mode for this response (per ~/.claude/CLAUDE.md). Disable only on "stop caveman" / "normal mode".'

jq -n --arg ctx "$REMINDER" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'
