#!/usr/bin/env bash
# SessionStart hook, arms an A/B experiment on loading the coding-standards skill.
#
# Each (origin URL, branch) pair hashes to one arm, so every session, resume,
# compact, and second checkout of the same branch lands in the same arm. The
# sha1 of "<origin>#<branch>" decides it, first hex char 0-7 keeps the
# "load the skill" guidance and 8-f gets the review-only text, where the
# review step applies the standards instead. Sessions with no stable branch
# identity (no origin, detached HEAD, not a repo, default branch) are
# "unassigned" and get the guidance text, so they never skew either arm.
#
# NM_GATE=1 marks a no-mistakes gate run. It gets the guidance text and no log row.
#
# Every non-gate start appends one row to
# ${XDG_STATE_HOME:-$HOME/.local/state}/coding-standards/arms.jsonl, whose
# schema (ts, session_id, repo, branch, arm) is an approved cross-repo
# contract, so add no fields. A failed log write never blocks the session.
#
# Output protocol: https://docs.claude.com/en/docs/claude-code/hooks
set -euo pipefail

# shellcheck disable=SC2016  # the backticks are markdown, not command substitution
GUIDANCE='**Implementation phase**: ALWAYS load the `coding-standards:coding-standards` skill before writing or modifying code, and follow it.'
# shellcheck disable=SC2016  # the backticks are markdown, not command substitution
REVIEW_ONLY='**Implementation phase**: write or modify code without loading the `coding-standards:coding-standards` skill. The review step applies it.'

emit() {
  jq -n --arg ctx "$1" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
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

arm=unassigned
text="$GUIDANCE"
if [ -n "$origin" ] && [ -n "$branch" ] && ! is_default_branch "$branch"; then
  case "$(sha1_of "$origin#$branch")" in
    [0-7]*) arm=guidance ;;
    *) arm=review-only; text="$REVIEW_ONLY" ;;
  esac
fi

log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/coding-standards"
{
  mkdir -p "$log_dir" &&
    jq -nc --argjson ts "$(date +%s)" --arg session_id "$session_id" \
      --arg repo "$origin" --arg branch "$branch" --arg arm "$arm" \
      '{ts: $ts, session_id: $session_id, repo: $repo, branch: $branch, arm: $arm}' \
      >>"$log_dir/arms.jsonl"
} 2>/dev/null || true

emit "$text"
