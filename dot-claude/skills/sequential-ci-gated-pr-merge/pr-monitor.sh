#!/bin/bash
# Monitor a PR: exit when CLEAN (ready to merge), UNSTABLE (required green but a
# non-required check is pending/failing - caller decides if it's applicable),
# BEHIND/main-advanced (re-sync needed), or a required check FAILS. Args: <pr> <repo>
set -uo pipefail
PR="$1"; REPO="$2"
BASE_MAIN="$(gh api "repos/$REPO/commits/main" --jq '.sha' 2>/dev/null)"
echo "baseline main=$BASE_MAIN"
DEADLINE=$(( $(date +%s) + 900 ))
while :; do
  NOW_MAIN="$(gh api "repos/$REPO/commits/main" --jq '.sha' 2>/dev/null)"
  read -r STATE MERGE < <(gh pr view "$PR" --repo "$REPO" --json mergeStateStatus,mergeable --jq '"\(.mergeStateStatus) \(.mergeable)"' 2>/dev/null)
  FAILED="$(gh pr checks "$PR" --repo "$REPO" 2>/dev/null | grep -Ec '\tfail\t|\terror\t' || true)"
  TS="$(date +%H:%M:%S)"
  echo "[$TS] state=$STATE mergeable=$MERGE failed=$FAILED main=${NOW_MAIN:0:12}"
  if [ -n "$NOW_MAIN" ] && [ "$NOW_MAIN" != "$BASE_MAIN" ]; then
    echo "RESULT=MAIN_ADVANCED"; exit 10
  fi
  case "$STATE" in
    BEHIND)  echo "RESULT=BEHIND"; exit 10 ;;
    CLEAN)   echo "RESULT=CLEAN"; exit 0 ;;
    UNSTABLE)
      # Required checks satisfied but a non-required check is pending/failing.
      # Surface them so the caller decides: merge if all are non-applicable,
      # else wait for the applicable one (e.g. a service pipeline this PR touches).
      echo "--- non-required not-yet-green checks ---"
      gh pr checks "$PR" --repo "$REPO" 2>/dev/null | grep -Ev $'\tskipping\t|\tpass\t' || true
      echo "RESULT=UNSTABLE"; exit 15 ;;
    DIRTY)   echo "RESULT=CONFLICT"; exit 30 ;;
  esac
  if [ "${FAILED:-0}" -gt 0 ]; then echo "RESULT=CHECK_FAILED"; exit 20; fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then echo "RESULT=TIMEOUT"; exit 40; fi
  sleep 30
done
