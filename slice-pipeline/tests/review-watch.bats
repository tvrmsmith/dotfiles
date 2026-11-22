# Each @test runs in its own subshell, so the stub knobs a test exports are
# meant to stay local to it.
# shellcheck disable=SC2030,SC2031
load helpers/assert
load helpers/stubs

# `slice-wave review-watch` runs in the review tab beside tuicr, judges each
# send in pull request 42's tuicr session, and answers the Archon review gate
# from it. Every external tool is a stub from helpers/stubs.bash, scripted per
# test. A watch that never decides ends when the run's status leaves paused,
# so each such test scripts a final `completed`.
HELPER="${BATS_TEST_DIRNAME}/../bin/slice-wave"

# A watch that loops forever is a failure, not a hang.
export BATS_TEST_TIMEOUT=60

# The worked examples' names: two session files, the pull request's head
# (the gh stub's default headRefOid) and some other commit.
P=/state/sessions/a.json
Q=/state/sessions/b.json
SHA=0123456789abcdef0123456789abcdef01234567
OTHER=fedcba9876543210fedcba9876543210fedcba98

setup() {
  command -v jq >/dev/null || skip "no jq"

  STUB_BIN="$(mktemp -d)"
  export STUB_BIN
  export FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures/axi"
  install_stubs

  OLD_PATH="$PATH"
  export PATH="$STUB_BIN:$PATH"

  # An open pull request, a watch that polls without sleeping, and a log
  # under the test's own state directory.
  export GH_PR_VIEW_STATES=OPEN
  export SLICE_WAVE_REVIEW_POLL_SECONDS=0
  export XDG_STATE_HOME="$STUB_BIN/state"
  LOG="$XDG_STATE_HOME/slice-pipeline/review-run-1.log"
}

teardown() {
  export PATH="$OLD_PATH"
  rm -rf "$STUB_BIN"
}

# Watches owner/repo#42 for run run-1.
watch() {
  "$HELPER" review-watch --run run-1 --pr 42 --repo owner/repo "$@"
}

# Prints what `tuicr review list` reports with PR 42's session at path $1,
# release count $2 and head $3 (null when omitted, absent when `missing`),
# beside another pull request's session that must never be read as it.
session() {
  jq -cn --arg path "$1" --argjson count "$2" --arg head "${3:-}" '
    {slug: "gh:owner/repo/pr/42", kind: "pr", path: $path, release_count: $count,
     head_sha: (if $head == "" then null else $head end)}
    | if $head == "missing" then del(.head_sha) else . end
    | [{slug: "gh:owner/repo/pr/7", kind: "pr", path: "/state/sessions/other.json",
        release_count: 9, head_sha: null}, .]'
}

# Prints what `tuicr review comments` reports: one comment per argument,
# released in the release it names (`null` for an edited comment).
comments_released_in() {
  local IFS=,
  local releases="[$*]"
  jq -cn --argjson releases "$releases" \
    '[$releases | to_entries[] | {id: "c\(.key)", content: "fix this", released_in: .value}]'
}

# Joins its arguments one per line, the shape TUICR_LIST_SEQUENCE takes.
reads() {
  local IFS=$'\n'
  printf '%s\n' "$*"
}

# Scripts the tuicr session reads, one per argument.
sessions() {
  TUICR_LIST_SEQUENCE="$(reads "$@")"
  export TUICR_LIST_SEQUENCE
}

# Prints every `archon workflow answer` the watch made, one per line, as
# `<pause> <choice> <text>`.
answers() {
  grep $'^archon\tworkflow answer' "$CALL_LOG" |
    sed -E 's/.*--occurrence ([^ ]+) --choose ([^ ]+) --text (.*) --as review-watch --json$/\1 \2 \3/'
}

# True once the detached `archon workflow resume run-1` has run, waiting up
# to 5 seconds for it.
resumed() {
  local tries=0
  until grep -q $'^archon\tworkflow resume run-1$' "$CALL_LOG"; do
    [ "$tries" -lt 50 ] || return 1
    tries=$((tries + 1))
    sleep 0.1
  done
}

@test "review-watch exits 2 with the usage line and calls nothing on a missing or malformed flag" {
  for bad in "--pr 42 --repo owner/repo" "--run run-1 --pr 0 --repo owner/repo" \
    "--run run-1 --pr 42 --repo 'owner/repo;x'" "--run 'run;1' --pr 42 --repo owner/repo" \
    "--run run-1 --pr 42 --repo owner/repo --since x"; do
    eval "set -- $bad"
    rc=0; out="$("$HELPER" review-watch "$@" 2>"$STUB_BIN/err")" || rc=$?
    equals "$bad $rc" "$bad 2"
    is_empty "$out"
    contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  done
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-watch approves an empty send on the pull request's head, resumes the run and exits (example 1)" {
  sessions "$(session "$P" 0)" "$(session "$P" 1 "$SHA")"
  rc=0; out="$(watch 2>&1)" || rc=$?
  equals "$rc" 0
  is_empty "$out"
  equals "$(answers)" "p1 approved $SHA"
  resumed
  contains "$(cat "$LOG")" "answered approved ($SHA) at pause p1"
  [ ! -e "$XDG_STATE_HOME/slice-pipeline/review-run-1.pid" ]
}

@test "review-watch answers comments for the comments sent after its baseline and keeps watching (example 2)" {
  export ARCHON_GET_SEQUENCE="paused:p1 paused:p1 completed"
  sessions "$(session "$P" 0)" "$(session "$P" 1)"
  TUICR_COMMENTS_JSON="$(comments_released_in 1 1)"
  export TUICR_COMMENTS_JSON
  rc=0; watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 comments 2 comments sent in release 1"
  resumed
  contains "$(cat "$LOG")" "run run-1 is completed, so the watch ends"
}

@test "review-watch counts only the comments the new release sent (example 3)" {
  export ARCHON_GET_SEQUENCE="paused:p1 paused:p1 completed"
  sessions "$(session "$P" 1)" "$(session "$P" 2 "$SHA")"
  TUICR_COMMENTS_JSON="$(comments_released_in 1 2 2)"
  export TUICR_COMMENTS_JSON
  rc=0; watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 comments 2 comments sent in release 2"
}

@test "review-watch approves a send whose only comment is an edited one with released_in null (example 4)" {
  sessions "$(session "$P" 1)" "$(session "$P" 2 "$SHA")"
  TUICR_COMMENTS_JSON="$(comments_released_in null)"
  export TUICR_COMMENTS_JSON
  rc=0; watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 approved $SHA"
}

@test "review-watch re-baselines on a new session file and approves the send in it (example 7)" {
  sessions "$(session "$P" 4)" "$(session "$Q" 1 "$SHA")"
  rc=0; watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 approved $SHA"
}

@test "review-watch judges the first session seen after none from release 0, so a send already in it approves (example 8)" {
  sessions '[]' '[]' "$(session "$P" 1 "$SHA")"
  rc=0; watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 approved $SHA"
}

@test "review-watch does not approve a send on a head other than the pull request's, and logs why (example 11)" {
  export ARCHON_GET_SEQUENCE="paused:p1 completed"
  sessions "$(session "$P" 0)" "$(session "$P" 1 "$OTHER")"
  rc=0; watch || rc=$?
  equals "$rc" 0
  is_empty "$(answers)"
  contains "$(cat "$LOG")" "reviewed head $OTHER, not the pull request's head $SHA"
}

@test "review-watch does not approve a send tuicr reports with a null or absent head_sha (example 12)" {
  for head in "" missing; do
    : >"$CALL_LOG"
    rm -f "$STUB_BIN/tuicr-list-calls" "$STUB_BIN/archon-get-calls"
    export ARCHON_GET_SEQUENCE="paused:p1 completed"
    sessions "$(session "$P" 0)" "$(session "$P" 1 "$head")"
    rc=0; watch || rc=$?
    equals "$rc" 0
    is_empty "$(answers)"
  done
  contains "$(cat "$LOG")" "tuicr reported no head_sha for the send at release 1"
}

@test "review-watch does not approve a quit without a send (example 14)" {
  export ARCHON_GET_SEQUENCE="paused:p1 paused:p1 completed"
  sessions "$(session "$P" 0 "$SHA")"
  rc=0; watch || rc=$?
  equals "$rc" 0
  is_empty "$(answers)"
}

# A lost baseline would judge the returning session from release 0 and
# approve the releases it held before the tab opened.
@test "review-watch keeps its baseline through a read where the session has disappeared" {
  export ARCHON_GET_SEQUENCE="paused:p1 paused:p1 paused:p1 completed"
  sessions "$(session "$P" 2 "$SHA")" '[]' "$(session "$P" 2 "$SHA")"
  rc=0; watch || rc=$?
  equals "$rc" 0
  is_empty "$(answers)"
}

@test "review-watch never takes a failed or unreadable first read as no session, so the releases it hid approve nothing" {
  for first in FAIL 'not json'; do
    : >"$CALL_LOG"
    rm -f "$STUB_BIN/tuicr-list-calls" "$STUB_BIN/archon-get-calls"
    export ARCHON_GET_SEQUENCE="paused:p1 paused:p1 completed"
    sessions "$first" "$(session "$P" 2 "$SHA")"
    rc=0; watch || rc=$?
    equals "$first $rc" "$first 0"
    is_empty "$(answers)"
  done
  contains "$(cat "$LOG")" "tuicr review list failed"
  contains "$(cat "$LOG")" "cannot read the tuicr review list"
}

@test "review-watch keeps watching through a tuicr that fails mid-watch, logging it (example 10)" {
  sessions "$(session "$P" 0)" FAIL "$(session "$P" 1 "$SHA")"
  rc=0; watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 approved $SHA"
  contains "$(cat "$LOG")" "tuicr review list failed"
}

@test "review-watch keeps watching through a failed gh read and judges the send once gh answers" {
  export GH_PR_VIEW_STATES="FAIL OPEN"
  sessions "$(session "$P" 0)" "$(session "$P" 1 "$SHA")"
  rc=0; watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 approved $SHA"
  contains "$(cat "$LOG")" "gh pr view 42 -R owner/repo failed"
}

@test "review-watch never approves a send whose comments tuicr fails to print or prints as no JSON" {
  sessions "$(session "$P" 0)" "$(session "$P" 1 "$SHA")"
  export TUICR_COMMENTS_EXIT=1
  export ARCHON_GET_SEQUENCE="paused:p1 completed"
  rc=0; watch || rc=$?
  equals "$rc" 0
  is_empty "$(answers)"
  contains "$(cat "$LOG")" "tuicr review comments failed"

  : >"$CALL_LOG"
  rm -f "$STUB_BIN/tuicr-list-calls" "$STUB_BIN/archon-get-calls"
  export TUICR_COMMENTS_EXIT=0 TUICR_COMMENTS_JSON='not json'
  rc=0; watch || rc=$?
  equals "$rc" 0
  is_empty "$(answers)"
  contains "$(cat "$LOG")" "cannot read the tuicr comments"
}

@test "review-watch exits without answering once the pull request is no longer open (example 13)" {
  export GH_PR_VIEW_STATES=CLOSED
  sessions "$(session "$P" 0)" "$(session "$P" 1 "$SHA")"
  rc=0; watch || rc=$?
  equals "$rc" 0
  is_empty "$(answers)"
  contains "$(cat "$LOG")" "pull request 42 is CLOSED, so the watch ends"
}

@test "review-watch holds an approval until the round reaches its gate" {
  export ARCHON_GET_SEQUENCE="running running paused:p1"
  sessions "$(session "$P" 0)" "$(session "$P" 1 "$SHA")"
  rc=0; watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 approved $SHA"
}

# After it answers comments the run stays paused at that pause until the
# resume lands, and the next round pauses afresh.
@test "review-watch answers each send at a pause of its own" {
  export ARCHON_GET_SEQUENCE="paused:p1 paused:p1 paused:p1 paused:p1 paused:p2"
  sessions "$(session "$P" 0)" "$(session "$P" 1)" "$(session "$P" 2 "$SHA")"
  TUICR_COMMENTS_JSON="$(comments_released_in 1)"
  export TUICR_COMMENTS_JSON
  rc=0; watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "$(printf 'p1 comments 1 comments sent in release 1\np2 approved %s' "$SHA")"
}

@test "review-watch drops a send whose gate refuses three answers, then keeps watching" {
  export ARCHON_ANSWER_EXIT=1
  export ARCHON_GET_SEQUENCE="paused:p1 paused:p1 paused:p1 paused:p1 completed"
  sessions "$(session "$P" 0)" "$(session "$P" 1 "$SHA")"
  rc=0; watch || rc=$?
  equals "$rc" 0
  equals "$(answers | wc -l | tr -d ' ')" 3
  contains "$(cat "$LOG")" "archon refused answer approved at pause p1"
  contains "$(cat "$LOG")" "dropped the approved send at release 1"
  contains "$(cat "$LOG")" "run run-1 is completed"
  lacks "$(cat "$CALL_LOG")" "workflow resume"
}

@test "review-watch exits when the run stops before its gate takes the send" {
  export ARCHON_GET_SEQUENCE="running cancelled"
  sessions "$(session "$P" 0)" "$(session "$P" 1 "$SHA")"
  rc=0; watch || rc=$?
  equals "$rc" 0
  is_empty "$(answers)"
  contains "$(cat "$LOG")" "run run-1 stopped before its gate took the approved send"
}

@test "review-watch keeps watching through archon reads it cannot use, logging each" {
  printf '#!/bin/bash\nprintf "archon\\t%%s\\n" "$*" >> "$CALL_LOG"\ncase "$2" in get) n=$(cat "$STUB_BIN/n" 2>/dev/null || echo 0); echo $((n + 1)) > "$STUB_BIN/n"\n  case "$n" in 0) exit 1 ;; 1) echo "not json" ;; 2) echo "{}" ;; *) echo "{\\"status\\":\\"failed\\"}" ;; esac ;; esac\n' >"$STUB_BIN/archon"
  sessions "$(session "$P" 0)"
  rc=0; watch || rc=$?
  equals "$rc" 0
  contains "$(cat "$LOG")" "archon workflow get run-1 failed"
  contains "$(cat "$LOG")" "cannot read archon workflow get run-1"
  contains "$(cat "$LOG")" "archon workflow get run-1 reported no status"
  contains "$(cat "$LOG")" "run run-1 is failed"
}

@test "review-watch keeps answering through an archon read that fails while it waits for the gate" {
  export ARCHON_GET_SEQUENCE="running FAIL paused:p1"
  sessions "$(session "$P" 0)" "$(session "$P" 1 "$SHA")"
  rc=0; watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 approved $SHA"
}

@test "review-watch leaves a run to the watcher already watching it" {
  mkdir -p "$XDG_STATE_HOME/slice-pipeline"
  echo "$$" >"$XDG_STATE_HOME/slice-pipeline/review-run-1.pid"
  rc=0; watch || rc=$?
  equals "$rc" 0
  is_empty "$(cat "$CALL_LOG")"
  contains "$(cat "$LOG")" "watcher $$ already watches run run-1"
}

@test "review-watch takes over a run whose recorded watcher is gone" {
  mkdir -p "$XDG_STATE_HOME/slice-pipeline"
  echo 999999 >"$XDG_STATE_HOME/slice-pipeline/review-run-1.pid"
  sessions "$(session "$P" 0)" "$(session "$P" 1 "$SHA")"
  rc=0; watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 approved $SHA"
}

@test "review-watch sleeps 15 seconds between passes by default" {
  unset SLICE_WAVE_REVIEW_POLL_SECONDS
  # shellcheck disable=SC2016 # The stub expands $CALL_LOG when it runs, not here.
  printf '#!/bin/bash\nprintf "sleep\\t%%s\\n" "$*" >> "$CALL_LOG"\n' > "$STUB_BIN/sleep"
  chmod +x "$STUB_BIN/sleep"
  sessions "$(session "$P" 0)" "$(session "$P" 0)" "$(session "$P" 1 "$SHA")"
  rc=0; watch || rc=$?
  equals "$rc" 0
  equals "$(grep '^sleep' "$CALL_LOG")" "$(printf 'sleep\t15')"
}

# GitHub mode (SLICE_WAVE_REVIEW=github): the watch reads the pull request's
# GitHub reviews instead of a tuicr session. Its first reviews read is the
# baseline, so each scripted sequence starts with the reviews already there.

# Watches owner/repo#42 for run run-1 in GitHub mode with trevor approving.
github_watch() {
  SLICE_WAVE_REVIEW=github SLICE_WAVE_REVIEW_APPROVERS="${APPROVERS-trevor}" watch "$@"
}

# Prints one review as GitHub's API reports it: id $1 by login $2 in state
# $3 on commit $4, with body $5.
review() {
  jq -cn --argjson id "$1" --arg login "$2" --arg state "$3" --arg commit "$4" --arg body "${5:-}" \
    '{id: $id, user: {login: $login}, state: $state, commit_id: $commit, body: $body}'
}

# Joins reviews into one JSON array, the shape of one reviews read.
reviews_of() {
  local IFS=,
  printf '[%s]\n' "$*"
}

# Scripts the reviews reads, one JSON array per argument.
review_reads() {
  GH_REVIEWS_SEQUENCE="$(reads "$@")"
  export GH_REVIEWS_SEQUENCE
}

@test "review-watch in GitHub mode approves an Approve review on the pull request's head and resumes the run" {
  review_reads '[]' "$(reviews_of "$(review 1 trevor APPROVED "$SHA")")"
  rc=0; out="$(github_watch 2>&1)" || rc=$?
  equals "$rc" 0
  is_empty "$out"
  equals "$(answers)" "p1 approved $SHA"
  resumed
  contains "$(cat "$LOG")" "watching the GitHub reviews of owner/repo#42 for run run-1 after review 0"
}

@test "review-watch in GitHub mode approves a Comment review whose whole body is /approve, in any case and spacing" {
  review_reads '[]' "$(reviews_of "$(review 1 trevor COMMENTED "$SHA" $'  /Approve\n')")"
  rc=0; github_watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 approved $SHA"
}

@test "review-watch in GitHub mode answers comments for an approval that carries inline comments" {
  export ARCHON_GET_SEQUENCE="paused:p1 paused:p1 completed"
  review_reads '[]' "$(reviews_of "$(review 1 trevor APPROVED "$SHA")")"
  export GH_REVIEW_COMMENTS_JSON='[{"id":11,"pull_request_review_id":1},{"id":12,"pull_request_review_id":1},{"id":13,"pull_request_review_id":99}]'
  rc=0; github_watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 comments 2 comments in GitHub review 1"
}

@test "review-watch in GitHub mode answers comments for changes requested even beside a later approval" {
  export ARCHON_GET_SEQUENCE="paused:p1 paused:p1 completed"
  review_reads '[]' "$(reviews_of "$(review 1 trevor CHANGES_REQUESTED "$SHA" "fix it")" "$(review 2 trevor APPROVED "$SHA")")"
  rc=0; github_watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 comments 1 comments in GitHub review 2"
}

@test "review-watch in GitHub mode answers comments for a Comment review with any other body" {
  export ARCHON_GET_SEQUENCE="paused:p1 paused:p1 completed"
  review_reads '[]' "$(reviews_of "$(review 1 trevor COMMENTED "$SHA" "/approve once you rename it")")"
  rc=0; github_watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 comments 1 comments in GitHub review 1"
}

@test "review-watch in GitHub mode ignores reviews by a login that is not an approver, and pending or dismissed ones" {
  export ARCHON_GET_SEQUENCE="paused:p1 completed"
  review_reads '[]' "$(reviews_of "$(review 1 claude-bot APPROVED "$SHA")" "$(review 2 trevor PENDING "$SHA")" "$(review 3 trevor DISMISSED "$SHA")")"
  rc=0; github_watch || rc=$?
  equals "$rc" 0
  is_empty "$(answers)"
}

@test "review-watch in GitHub mode trusts every login in a comma-separated approver list" {
  review_reads '[]' "$(reviews_of "$(review 1 sam APPROVED "$SHA")")"
  APPROVERS="trevor, sam"
  rc=0; github_watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 approved $SHA"
}

@test "review-watch in GitHub mode does not count a review made before the watch started" {
  export ARCHON_GET_SEQUENCE="paused:p1 completed"
  review_reads "$(reviews_of "$(review 5 trevor APPROVED "$SHA")")"
  rc=0; github_watch || rc=$?
  equals "$rc" 0
  is_empty "$(answers)"
  contains "$(cat "$LOG")" "after review 5"
}

@test "review-watch in GitHub mode does not approve an approval of a stale head, logs why, and approves the next one" {
  export ARCHON_GET_SEQUENCE="paused:p1 paused:p1"
  review_reads '[]' "$(reviews_of "$(review 1 trevor APPROVED "$OTHER")")" \
    "$(reviews_of "$(review 1 trevor APPROVED "$OTHER")" "$(review 2 trevor APPROVED "$SHA")")"
  rc=0; github_watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 approved $SHA"
  contains "$(cat "$LOG")" "the approving review 1 covered head $OTHER, not the pull request's head $SHA"
}

@test "review-watch in GitHub mode waits out a failed reviews read at the baseline and after it" {
  review_reads FAIL '[]' FAIL "$(reviews_of "$(review 1 trevor APPROVED "$SHA")")"
  rc=0; github_watch || rc=$?
  equals "$rc" 0
  equals "$(answers)" "p1 approved $SHA"
  contains "$(cat "$LOG")" "gh could not list the reviews of pull request 42"
}

@test "review-watch in GitHub mode judges nothing while the inline comments cannot be read" {
  export ARCHON_GET_SEQUENCE="paused:p1 completed" GH_REVIEW_COMMENTS_EXIT=1
  review_reads '[]' "$(reviews_of "$(review 1 trevor APPROVED "$SHA")")"
  rc=0; github_watch || rc=$?
  equals "$rc" 0
  is_empty "$(answers)"
  contains "$(cat "$LOG")" "gh could not list the review comments of pull request 42"
}

@test "review-watch in GitHub mode ends when the pull request is no longer open" {
  export GH_PR_VIEW_STATES=CLOSED
  review_reads '[]'
  rc=0; github_watch || rc=$?
  equals "$rc" 0
  is_empty "$(answers)"
  contains "$(cat "$LOG")" "pull request 42 is CLOSED, so the watch ends"
}

@test "review-watch in GitHub mode exits 1 and logs why when no approver is set" {
  APPROVERS=""
  rc=0; github_watch || rc=$?
  equals "$rc" 1
  contains "$(cat "$LOG")" "needs SLICE_WAVE_REVIEW_APPROVERS"
  is_empty "$(grep $'^gh\t' "$CALL_LOG")"
  [ ! -e "$XDG_STATE_HOME/slice-pipeline/review-run-1.pid" ]
}
