#!/usr/bin/env bash
#
# adr-guard.sh — PreToolUse guard for ADR directories.
#
# ADRs record decisions that were already made. Rewriting one is a decision
# change, not a code fix, so it is never something an automated review pass
# should do on its own. The no-mistakes review step did it 12 times to a single
# accepted ADR on one branch; every rewrite was editorial, none changed the
# decision.
#
# Behaviour depends on who is running:
#
#   NM_GATE=1 (set by nm-claude, i.e. a no-mistakes gate step agent)
#     read  -> guidance injected, normal permission flow
#     write -> DENY
#
#   interactive session (no NM_GATE)
#     read  -> guidance injected, normal permission flow
#     write -> guidance injected, normal permission flow
#
# Anything not touching an ADR path exits silently and costs nothing.
#
# Edit/Write/MultiEdit/NotebookEdit is the surface this covers reliably. Bash is
# classified by pattern, so an unusual writer (an inline python or node script)
# still gets through.
#
# Wired in dot-claude/settings.json under PreToolUse.

set -uo pipefail

payload="$(cat)"

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
[ -n "$tool" ] || exit 0

# Every ADR lives in a `docs/adr/` directory, at the repo root or under a
# service/product subtree. Match the segment, not any one location. The leading
# class also has to admit a path sitting mid-command-line (`rm docs/adr/x`).
ADR_RE='(^|[^[:alnum:]_-])docs/adr/'

case "$tool" in
  Read|Edit|Write|MultiEdit|NotebookEdit)
    target="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
    ;;
  Bash)
    target="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
    ;;
  *)
    exit 0
    ;;
esac

[ -n "$target" ] || exit 0
printf '%s' "$target" | grep -Eq "$ADR_RE" || exit 0

# Classify the access as read or write.
case "$tool" in
  Read)
    access="read"
    ;;
  Edit|Write|MultiEdit|NotebookEdit)
    access="write"
    ;;
  Bash)
    # A shell command is a write only if it actually mutates. Plain inspection
    # (cat, rg, git log, git show, ls) stays a read so the guard does not
    # obstruct the reading an ADR is there for.
    if printf '%s' "$target" | grep -Eq '(>>?[[:space:]]*[^|&;]*docs/adr/|[[:space:]]tee[[:space:]]|sed[[:space:]]+-[a-zA-Z]*i|\bperl\b[^|]*-[a-zA-Z]*i|\b(rm|mv|cp|truncate|install)\b|git[[:space:]]+(apply|checkout|restore|mv|rm)\b|\bpatch\b)'; then
      access="write"
    else
      access="read"
    fi
    ;;
esac

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
}

# No permissionDecision: the call keeps going through the normal permission
# flow. Deciding "allow" here would suppress the prompt this guard exists to
# make more informed.
guide() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $r
    }
  }'
}

READ_GUIDANCE='ADR directory. An ADR is a decision already made, not a draft. Read it as a constraint on the change under review: code that contradicts it is the finding, the ADR is not. If the ADR itself looks wrong, that is a decision to escalate to the user, not an edit to make.'

WRITE_GUIDANCE='ADR directory. Per docs/adr/README.md an accepted ADR is amended for corrections and superseded by a new numbered ADR when the decision changes — it is not rewritten in place, and never reworded for style. Confirm with the user which of those two this is before writing.'

GATE_DENY='Blocked: no-mistakes gate agents do not write ADRs. An ADR is a decision the user already made; changing it is the user'"'"'s call, not a review fix. Per docs/adr/README.md the paths are amend (correction) or supersede with a new numbered ADR (decision changed) — both human-initiated. If the diff genuinely contradicts an accepted ADR, report that as a finding against the CODE and let it reach the user. Do not edit, reword, restructure, or renumber anything under docs/adr/.'

if [ "$access" = "write" ] && [ "${NM_GATE:-}" = 1 ]; then
  deny "$GATE_DENY"
  exit 0
fi

if [ "$access" = "write" ]; then
  guide "$WRITE_GUIDANCE"
else
  guide "$READ_GUIDANCE"
fi

exit 0
