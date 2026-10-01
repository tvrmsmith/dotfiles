#!/usr/bin/env bash
# SessionStart / SubagentStart hook, arms an A/B experiment on loading the
# coding-standards skill.
#
# Each (origin URL, branch) pair hashes to one arm, so every session, resume,
# clear, compact, and second checkout of the same branch lands in the same arm. The
# sha1 of "<origin>#<branch>" decides it, first hex char 0-7 keeps the
# "load the skill" guidance and 8-f gets the review-only text, where the
# review step applies the standards instead. Sessions with no stable branch
# identity (no origin, detached HEAD, not a repo, default branch) are
# "unassigned" and get the guidance text, so they never skew either arm. A
# failed or empty hash also stays unassigned rather than logging a fake arm.
#
# NM_GATE=1 marks a no-mistakes gate run. It gets the guidance text and no log row.
#
# Every non-gate SessionStart (startup, resume, clear, compact) appends one row to
# ${XDG_STATE_HOME:-$HOME/.local/state}/coding-standards/arms.jsonl, whose
# schema (ts, session_id, repo, branch, arm) is an approved cross-repo
# contract, so add no fields. A failed log write never blocks the session.
#
# --subagent runs on SubagentStart. Subagents never fire SessionStart, so it
# injects the arm its session last logged and writes no log row. Reading the
# log rather than the payload cwd keeps one session in one arm after a branch
# switch, and for a worktree-isolated subagent, whose cwd is its own worktree.
# A session with no row (failed log write) falls back to hashing the cwd.
#
# Output protocol: https://docs.claude.com/en/docs/claude-code/hooks
set -euo pipefail

EVENT="SessionStart"
if [ "${1-}" = "--subagent" ]; then
  EVENT="SubagentStart"
fi

# shellcheck disable=SC2016  # the backticks are markdown, not command substitution
GUIDANCE='**Implementation phase**: ALWAYS load the `coding-standards:coding-standards` skill before writing or modifying code, and follow it.'
# shellcheck disable=SC2016  # the backticks are markdown, not command substitution
REVIEW_ONLY='**Implementation phase**: write or modify code without loading the `coding-standards:coding-standards` skill. The review step applies it.'

emit() {
  jq -n --arg event "$EVENT" --arg ctx "$1" '{hookSpecificOutput: {hookEventName: $event, additionalContext: $ctx}}'
}

sha1_of() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 1
  else
    printf '%s' "$1" | sha1sum
  fi
}

if [ "${NM_GATE-}" = "1" ]; then
  emit "$GUIDANCE"
  exit 0
fi

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // ""')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"

origin="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
branch="$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || true)"

is_default_branch() {
  local default
  default="$(git -C "$cwd" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$default" ]; then
    [ "$1" = "${default#origin/}" ]
  else
    [ "$1" = main ] || [ "$1" = master ]
  fi
}

text_for() {
  if [ "$1" = review-only ]; then
    printf '%s' "$REVIEW_ONLY"
  else
    printf '%s' "$GUIDANCE"
  fi
}

log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/coding-standards"
log="$log_dir/arms.jsonl"

# fromjson? skips a torn or corrupt line instead of ending the scan there.
logged_arm() {
  [ -n "$session_id" ] || return 0
  jq -rR --arg s "$session_id" 'fromjson? | select(.session_id == $s) | .arm' "$log" 2>/dev/null |
    tail -n 1
}

arm=unassigned
if [ -n "$origin" ] && [ -n "$branch" ] && ! is_default_branch "$branch"; then
  case "$(sha1_of "$origin#$branch")" in
    [0-7]*) arm=guidance ;;
    [89a-f]*) arm=review-only ;;
  esac
fi

if [ "$EVENT" = "SubagentStart" ]; then
  inherited="$(logged_arm || true)"
  emit "$(text_for "${inherited:-$arm}")"
  exit 0
fi

{
  mkdir -p "$log_dir" &&
    jq -nc --argjson ts "$(date +%s)" --arg session_id "$session_id" \
      --arg repo "$origin" --arg branch "$branch" --arg arm "$arm" \
      '{ts: $ts, session_id: $session_id, repo: $repo, branch: $branch, arm: $arm}' \
      >>"$log"
} 2>/dev/null || true

emit "$(text_for "$arm")"
