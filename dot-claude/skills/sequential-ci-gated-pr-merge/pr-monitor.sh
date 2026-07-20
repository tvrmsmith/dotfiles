#!/bin/bash
# Monitor a PR and exit on a terminal state:
#   CLEAN         - mergeable, every REQUIRED check green (exit 0)
#   UNSTABLE      - all REQUIRED checks green, but an OPTIONAL check is pending or
#                   failing; the caller maps it to the PR's changed paths and
#                   decides merge-vs-wait (exit 15)
#   BEHIND / MAIN_ADVANCED - branch fell behind or main moved; re-sync (exit 10)
#   CHECK_FAILED  - a REQUIRED check failed (exit 20)
#   CONFLICT      - merge conflict (exit 30)
#   TIMEOUT       - 15 min elapsed, no terminal state (exit 40)
# Required-vs-optional is read from the branch's rulesets (GitHub's mergeStateStatus
# alone won't tell the caller WHICH pending check matters), so an optional check can
# never block the merge on its own or falsely abort it. Args: <pr> <repo>
set -uo pipefail
PR="$1"; REPO="$2"

# Required status-check contexts: rulesets first, classic branch-protection fallback.
REQUIRED="$(gh api "repos/$REPO/rules/branches/main" \
  --jq '.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context' 2>/dev/null)"
[ -z "$REQUIRED" ] && REQUIRED="$(gh api "repos/$REPO/branches/main/protection/required_status_checks/contexts" --jq '.[]' 2>/dev/null)"
echo "required-contexts: $(printf '%s' "$REQUIRED" | paste -sd, - 2>/dev/null)"
is_required() { printf '%s\n' "$REQUIRED" | grep -Fxq "$1"; }

BASE_MAIN="$(gh api "repos/$REPO/commits/main" --jq '.sha' 2>/dev/null)"
echo "baseline main=$BASE_MAIN"
DEADLINE=$(( $(date +%s) + 900 ))
while :; do
  NOW_MAIN="$(gh api "repos/$REPO/commits/main" --jq '.sha' 2>/dev/null)"
  read -r STATE MERGE < <(gh pr view "$PR" --repo "$REPO" --json mergeStateStatus,mergeable --jq '"\(.mergeStateStatus) \(.mergeable)"' 2>/dev/null)
  CHECKS="$(gh pr checks "$PR" --repo "$REPO" 2>/dev/null)"

  # Count REQUIRED failures only - an optional check failing must not abort the merge.
  REQ_FAILED=0
  while IFS=$'\t' read -r name state _; do
    case "$state" in fail|error) is_required "$name" && REQ_FAILED=$((REQ_FAILED+1)) ;; esac
  done <<< "$CHECKS"

  TS="$(date +%H:%M:%S)"
  echo "[$TS] state=$STATE mergeable=$MERGE req-failed=$REQ_FAILED main=${NOW_MAIN:0:12}"

  if [ -n "$NOW_MAIN" ] && [ "$NOW_MAIN" != "$BASE_MAIN" ]; then echo "RESULT=MAIN_ADVANCED"; exit 10; fi
  if [ "$REQ_FAILED" -gt 0 ]; then echo "RESULT=CHECK_FAILED"; exit 20; fi

  case "$STATE" in
    BEHIND)  echo "RESULT=BEHIND"; exit 10 ;;
    CLEAN)   echo "RESULT=CLEAN"; exit 0 ;;
    UNSTABLE)
      # Every REQUIRED check is green; only optional checks are pending/failing.
      # Report both halves so the caller can decide merge-vs-wait: (1) required
      # gate is satisfied, (2) exactly which checks are still not green and
      # whether each is required or optional. The caller maps the optional ones
      # to the PR's changed paths - merge (unrelated / systemic) or wait (the
      # check exercises a service this PR changed).
      echo "required-gate: SATISFIED (all required checks green)"
      echo "--- checks still not green ---"
      while IFS=$'\t' read -r name state _; do
        case "$state" in pass|skipping|"") continue ;; esac
        if is_required "$name"; then lbl="[required]"; else lbl="[optional]"; fi
        echo "$lbl  $state  $name"
      done <<< "$CHECKS"
      echo "RESULT=UNSTABLE"; exit 15 ;;
    DIRTY)   echo "RESULT=CONFLICT"; exit 30 ;;
  esac

  if [ "$(date +%s)" -ge "$DEADLINE" ]; then echo "RESULT=TIMEOUT"; exit 40; fi
  sleep 30
done
