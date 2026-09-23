#!/usr/bin/env bash
#
# waiver-guard.sh — PreToolUse gate on coding-standards lint waivers.
#
# The personal lint gate (~/dev/personal/coding-standards) blocks a commit on
# any finding touching a changed line, and its only way past a false positive is
# `lint-changed waive`, which appends a one-shot record to
# ${XDG_STATE_HOME:-~/.local/state}/coding-standards/waivers.jsonl. The log makes
# a waiver auditable after the fact; this hook makes Trevor approve it before.
#
# Three outcomes:
#   - `lint-changed waive` in a session with a human → "ask". The permission
#     prompt shows the full command, --reason included, so approving is reading
#     the agent's case for the false positive.
#   - The same command in an unattended run → allowed, approval deferred to the
#     end. A prompt there either hangs the run or is silently answered, and one
#     false positive must not cost a slice-wave its slice. `slice-wave
#     verify-commit` lists every waiver spent on the slice's commits, read from
#     the log by tree sha, and Trevor reviews that list before merging.
#   - Hand-writing the log, by file tool or shell redirect → "deny". It skips the
#     approval above and the record format lint-changed matches on.
#
# Unattended means no terminal is driving the session (Archon's SDK nodes and
# `claude -p` set CLAUDE_CODE_ENTRYPOINT to something other than "cli"), or
# /afk is armed and unexpired.
#
# `lint-changed waivers` (the listing) and reading the log stay open.
#
# Wired in dot-claude/settings.json under PreToolUse.

set -uo pipefail

payload="$(cat)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"

unattended() {
  case "${CLAUDE_CODE_ENTRYPOINT:-cli}" in cli) ;; *) return 0 ;; esac
  local flag="$HOME/.claude/afk" expiry
  [ -r "$flag" ] || return 1
  expiry="$(head -n1 "$flag")"
  [ "${expiry:-0}" -gt "$(date +%s)" ] 2>/dev/null
}

decide() {
  jq -n --arg d "$1" --arg r "$2" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $d,
      permissionDecisionReason: $r
    }
  }'
}

LOG_RE='(^|/)waivers\.jsonl$'

HAND_EDIT_DENY='Blocked: the waiver log is written only by `lint-changed waive`, which asks Trevor first. Run the waive command the lint finding printed, exactly as printed.'

case "$tool" in
  Edit|Write|MultiEdit)
    target="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"
    printf '%s' "$target" | grep -Eq "$LOG_RE" && decide deny "$HAND_EDIT_DENY"
    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0

# lint-changed is printed by absolute path and may be quoted; `waivers` (the
# listing) must not match, hence the word boundary after `waive`.
if printf '%s' "$command" | grep -Eq "lint-changed[\"']?[[:space:]]+waive([[:space:]]|$)"; then
  if unattended; then
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        additionalContext: "Unattended run, so this waiver is recorded now and Trevor approves it at the end, before merge. Write the --reason for that reviewer: the rule, why the finding is a false positive, and what fixing it would cost. Name the waiver in your final report."
      }
    }'
  else
    decide ask 'Coding-standards lint waiver. Approve only if the --reason convinces you the finding is a false positive; deny and the agent fixes the code instead.'
  fi
  exit 0
fi

if printf '%s' "$command" | grep -Eq '(>>?|[[:space:]]tee([[:space:]]+-a)?)[[:space:]]*[^|&;[:space:]]*waivers\.jsonl'; then
  decide deny "$HAND_EDIT_DENY"
fi
exit 0
