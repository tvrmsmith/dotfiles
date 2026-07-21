#!/bin/bash
# Monitor a PR and exit on a terminal state:
#   CLEAN         - mergeable, every REQUIRED check green (exit 0)
#   UNSTABLE      - all REQUIRED checks green, but an OPTIONAL check is pending or
#                   failing; the caller maps it to the PR's changed paths and
#                   decides merge-vs-wait (exit 15)
#   BEHIND / MAIN_ADVANCED - branch fell behind or base moved; re-sync (exit 10).
#                   A base advance only forces MAIN_ADVANCED when the base is STRICT
#                   (requires up-to-date branches) or required checks are still pending
#                   (stale run). A non-strict base that is still CLEAN falls through.
#   CHECK_FAILED  - a REQUIRED check failed, was cancelled, or timed out (exit 20)
#   CONFLICT      - merge conflict (exit 30)
#   TIMEOUT       - 15 min elapsed, no terminal state (exit 40)
#   REQUIRED_UNKNOWN - required-check set unreadable; can't gate safely (exit 50)
#   (usage error - wrong arg count - exit 64)
# Required-vs-optional is read from the branch's rulesets (GitHub's mergeStateStatus
# alone won't tell the caller WHICH pending check matters), so an optional check can
# never block the merge on its own or falsely abort it. Args: <pr> <repo>
set -uo pipefail
[ $# -eq 2 ] || { echo "usage: pr-monitor.sh <pr> <repo>" >&2; exit 64; }
PR="$1"; REPO="$2"

# Gate against the PR's ACTUAL base branch (not a hardcoded main - a PR may target a
# release branch with a different required set).
BASE_REF=""
for _attempt in 1 2 3; do
  BASE_REF="$(gh pr view "$PR" --repo "$REPO" --json baseRefName --jq '.baseRefName' 2>/dev/null)"
  [ -n "$BASE_REF" ] && break
  [ "$_attempt" -lt 3 ] && sleep 2
done
# Do NOT assume "main" on a transient failure: a wrong base would poison the required-check
# set, the strict-policy read, and the baseline SHA - gating the PR against the WRONG base.
# Better to STOP and have the caller verify (REQUIRED_UNKNOWN) than silently mis-gate.
if [ -z "$BASE_REF" ]; then
  echo "WARNING: could not read the PR's base branch (baseRefName) after retries"
  echo "  (transient gh/1Password failure?). Refusing to assume 'main' - that could gate"
  echo "  this PR against the wrong base's required-check set."
  echo "RESULT=REQUIRED_UNKNOWN"; exit 50
fi
echo "base-branch=$BASE_REF"

# Required status-check contexts: rulesets first, classic branch-protection fallback.
REQUIRED="$(gh api "repos/$REPO/rules/branches/$BASE_REF" \
  --jq '.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context' 2>/dev/null)"
[ -z "$REQUIRED" ] && REQUIRED="$(gh api "repos/$REPO/branches/$BASE_REF/protection/required_status_checks/contexts" --jq '.[]' 2>/dev/null)"

# Fail safe: if the required set can't be read, we cannot label required-vs-optional
# or gate safely (everything would look optional and a required failure would never
# trip CHECK_FAILED). Refuse to run so the caller stops and verifies rather than
# silently merging past a required check.
# BY DESIGN: a base branch with legitimately ZERO required checks also lands here and is
# treated as REQUIRED_UNKNOWN. This skill exists to gate CI-gated merges; a base with
# nothing to gate is intentionally out of scope, so we do not attempt to distinguish
# "empty by config" from "unreadable" - both stop the caller for a human decision.
if [ -z "$REQUIRED" ]; then
  echo "WARNING: could not read required status-check contexts for '$BASE_REF'"
  echo "  (rulesets + classic branch protection both empty/unreadable - check token scope or base branch,"
  echo "  or the base has no required checks configured)."
  echo "  Cannot gate required-vs-optional safely; refusing to run."
  echo "RESULT=REQUIRED_UNKNOWN"; exit 50
fi
echo "required-contexts: $(printf '%s' "$REQUIRED" | paste -sd, - 2>/dev/null)"

# Strict = base branch requires PR branches be up-to-date before merge. When strict,
# any base-branch advance means this PR is now stale and must re-sync. When non-strict,
# a base advance alone does NOT block the PR - let GitHub's mergeStateStatus decide.
# Rulesets first, classic branch-protection fallback. If unreadable, default to strict
# (safe: forces a re-sync rather than risk merging a stale branch).
STRICT="$(gh api "repos/$REPO/rules/branches/$BASE_REF" \
  --jq 'first(.[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy)' 2>/dev/null)"
[ -z "$STRICT" ] && STRICT="$(gh api "repos/$REPO/branches/$BASE_REF/protection/required_status_checks" --jq '.strict' 2>/dev/null)"
[ "$STRICT" = "true" ] || [ "$STRICT" = "false" ] || STRICT=true
echo "strict-up-to-date=$STRICT"

# is_required: exact full-name match first; then, only for a matrix leg "name (X)",
# fall back to the stripped base ("build (18.x)" -> "build") matching a required
# context EXACTLY. The strip fallback is SUPPRESSED when a check whose exact name
# equals that base already exists in the current CHECKS set: there the bare check
# owns the required context and "name (X)" is a distinct (optional) leg that merely
# shares the prefix - e.g. required "deploy" + optional "deploy (preview)". Without
# this guard a failing optional matrix leg would falsely trip CHECK_FAILED and halt
# a mergeable train. No broad substring matching - a stripped base must still equal
# a required context. Relies on $CHECKS (set each loop iteration before any call).
is_required() {
  printf '%s\n' "$REQUIRED" | grep -Fxq "$1" && return 0
  case "$1" in
    *" ("*)
      local base="${1% (*}"
      printf '%s\n' "$REQUIRED" | grep -Fxq "$base" || return 1
      # A bare check named exactly "$base" already owns this required context, so
      # this "$base (...)" leg is a separate optional check - do not strip-classify it.
      printf '%s\n' "$CHECKS" | cut -f1 | grep -Fxq "$base" && return 1
      return 0 ;;
  esac
  return 1
}

# Baseline base SHA drives main-advance detection. A single transient-empty fetch
# (1Password/gh auth timeout) would otherwise leave BASE_MAIN empty for the whole
# run and permanently disable SHA-based main-advance detection (line ~97 guard),
# silently degrading to mergeStateStatus=BEHIND only. Retry a few times before
# accepting an empty baseline, and if still empty print an explicit warning so the
# degradation is visible (do NOT abort - the mergeStateStatus path still gates safely).
BASE_MAIN=""
for _attempt in 1 2 3; do
  BASE_MAIN="$(gh api "repos/$REPO/commits/$BASE_REF" --jq '.sha' 2>/dev/null)"
  [ -n "$BASE_MAIN" ] && break
  [ "$_attempt" -lt 3 ] && sleep 2
done
[ -z "$BASE_MAIN" ] && echo "WARNING: baseline base SHA unreadable - main-advance detection degraded to BEHIND-only"
echo "baseline $BASE_REF=$BASE_MAIN"
DEADLINE=$(( $(date +%s) + 900 ))
while :; do
  NOW_MAIN="$(gh api "repos/$REPO/commits/$BASE_REF" --jq '.sha' 2>/dev/null)"
  read -r STATE MERGE < <(gh pr view "$PR" --repo "$REPO" --json mergeStateStatus,mergeable --jq '"\(.mergeStateStatus) \(.mergeable)"' 2>/dev/null)
  CHECKS="$(gh pr checks "$PR" --repo "$REPO" 2>/dev/null)"

  # Count REQUIRED failures only - an optional check failing must not abort the merge.
  # A cancelled or timed-out required check counts as a failure too: it will never go
  # green on its own, so treating it as neutral would just spin the monitor to TIMEOUT.
  REQ_FAILED=0
  REQ_PENDING=0
  while IFS=$'\t' read -r name state _; do
    case "$state" in
      fail|error|cancel|cancelled|timed_out|timeout) is_required "$name" && REQ_FAILED=$((REQ_FAILED+1)) ;;
      pending) is_required "$name" && REQ_PENDING=$((REQ_PENDING+1)) ;;
    esac
  done <<< "$CHECKS"

  TS="$(date +%H:%M:%S)"
  echo "[$TS] state=$STATE mergeable=$MERGE req-failed=$REQ_FAILED main=${NOW_MAIN:0:12}"

  # Base branch advanced since baseline. Only force a re-sync (MAIN_ADVANCED) when the
  # branch is actually stale: STRICT bases always require up-to-date, so re-sync; a
  # non-strict base only needs re-sync if required checks are still pending (a run that
  # is now stale against the new base). Otherwise fall through and let mergeStateStatus
  # (BEHIND/CLEAN/UNSTABLE) drive - a non-strict CLEAN PR stays mergeable. Require both
  # shas known so a transient baseline-fetch failure ($BASE_MAIN empty) never fires.
  if [ -n "$BASE_MAIN" ] && [ -n "$NOW_MAIN" ] && [ "$NOW_MAIN" != "$BASE_MAIN" ]; then
    if [ "$STRICT" = "true" ] || [ "$REQ_PENDING" -gt 0 ]; then
      echo "RESULT=MAIN_ADVANCED"; exit 10
    fi
  fi
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
