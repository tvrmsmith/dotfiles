# Each @test runs in its own subshell, so the stub knobs a test exports are
# meant to stay local to it.
# shellcheck disable=SC2030,SC2031
load helpers/assert
load helpers/stubs

# `slice-wave review-round` opens the review tab for a delivered slice's pull
# request and waits for the engineer to send from it. Every external tool but
# git is a stub from helpers/stubs.bash, scripted per test.
HELPER="${BATS_TEST_DIRNAME}/../bin/slice-wave"

# The worked examples' names: two session files, the pull request's head
# (the gh stub's default headRefOid) and some other commit.
P=/state/sessions/a.json
Q=/state/sessions/b.json
SHA=0123456789abcdef0123456789abcdef01234567
OTHER=fedcba9876543210fedcba9876543210fedcba98

setup() {
  command -v jq >/dev/null || skip "no jq"

  # See slice-wave.bats: the developer's signing config would hang commits.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  STUB_BIN="$(mktemp -d)"
  export STUB_BIN
  export FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures/axi"
  install_stubs

  OLD_PATH="$PATH"
  export PATH="$STUB_BIN:$PATH"

  REPO="$(mktemp -d)"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test \
    commit --quiet --allow-empty -m base

  # An open pull request, and a review that polls without sleeping and
  # stops after one pass unless a test gives it longer.
  export GH_PR_VIEW_STATES=OPEN
  export SLICE_WAVE_REVIEW_POLL_SECONDS=0 SLICE_WAVE_REVIEW_WAIT_SECONDS=0
}

teardown() {
  export PATH="$OLD_PATH"
  rm -rf "$STUB_BIN" "$REPO"
}

review_round() {
  ( cd "$REPO" && "$HELPER" review-round "$@" )
}

field() {
  printf '%s' "$1" | jq -r ".$2"
}

# One review round for bead demo-1 on owner/repo#42, resuming from cursor $1.
round() {
  review_round --bead demo-1 --delivered true --pr 42 --repo owner/repo --since "$1"
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

# Scripts a session whose next read is a send with no comments on the pull
# request's head, so a round resumed from cursor 2:$P approves in one pass.
approving_session() {
  TUICR_LIST_SEQUENCE="$(session "$P" 3 "$SHA")"
  export TUICR_LIST_SEQUENCE
}

# Prints what `orca terminal list --json --include-visual-layouts` reports
# with $1 as .result.visualLayouts. The terminal's own title names the review
# tab, since a program in the pane can set it, and it must never count.
layouts() {
  jq -cn --argjson layouts "$1" \
    '{ok: true, result: {terminals: [{handle: "term_1", title: "review demo-1 #42"}], visualLayouts: $layouts}}'
}

# Prints what `orca repo list --json` reports with a repository at $1 beside
# one elsewhere.
repos() {
  jq -cn --arg path "$1" \
    '{ok: true, result: {repos: [{id: "r1", path: "/elsewhere"}, {id: "r2", path: $path}]}}'
}

# Joins its arguments one per line, the shape TUICR_LIST_SEQUENCE takes.
reads() {
  local IFS=$'\n'
  printf '%s\n' "$*"
}

@test "review-round reports undelivered and calls nothing when the slice was not delivered" {
  rc=0; out="$(review_round --bead demo-1 --delivered false --pr 0 --repo '' --since '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" undelivered
  equals "$(field "$out" approved)" false
  equals "$(field "$out" cursor)" ""
  equals "$(field "$out" head_sha)" ""
  equals "$(field "$out" comments)" 0
  contains "$(field "$out" reason)" "not delivered"
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-round exits 2 with the usage line and calls nothing on an unknown flag" {
  rc=0; out="$(review_round --bead demo-1 --delivered false --pr 0 --repo '' --since '' --focus yes 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "unknown flag --focus"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-round exits 2 with the usage line and calls nothing when --delivered is neither true nor false" {
  rc=0; out="$(review_round --bead demo-1 --delivered maybe --pr 42 --repo owner/repo --since '' 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "--delivered must be true or false, not 'maybe'"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-round exits 2 with the usage line and calls nothing when any of its five flags is missing" {
  for missing in --bead --delivered --pr --repo --since; do
    args=()
    for pair in "--bead demo-1" "--delivered false" "--pr 0" "--repo owner/repo" "--since 1:/s.json"; do
      [ "${pair%% *}" = "$missing" ] || args+=("${pair%% *}" "${pair#* }")
    done
    rc=0; out="$(review_round "${args[@]}" 2>"$STUB_BIN/err")" || rc=$?
    equals "$missing $rc" "$missing 2"
    is_empty "$out"
    contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  done
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-round approves a send with no comments on the pull request's head (example 6)" {
  TUICR_LIST_SEQUENCE="$(session "$P" 3 "$SHA")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round "2:$P")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" approved
  equals "$(field "$out" approved)" true
  equals "$(field "$out" cursor)" "3:$P"
  equals "$(field "$out" head_sha)" "$SHA"
  equals "$(field "$out" comments)" 0
}

@test "review-round counts only the comments the new release sent (example 3)" {
  TUICR_LIST_SEQUENCE="$(session "$P" 2 "$SHA")"
  export TUICR_LIST_SEQUENCE
  TUICR_COMMENTS_JSON="$(comments_released_in 1 2 2)"
  export TUICR_COMMENTS_JSON
  rc=0; out="$(round "1:$P")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" comments
  equals "$(field "$out" approved)" false
  equals "$(field "$out" comments)" 2
  equals "$(field "$out" cursor)" "2:$P"
  contains "$(cat "$CALL_LOG")" "$(printf 'tuicr\treview comments --session gh:owner/repo/pr/42')"
}

@test "review-round approves a send whose only comment is an edited one with released_in null (example 4)" {
  TUICR_LIST_SEQUENCE="$(session "$P" 2 "$SHA")"
  export TUICR_LIST_SEQUENCE
  TUICR_COMMENTS_JSON="$(comments_released_in null)"
  export TUICR_COMMENTS_JSON
  rc=0; out="$(round "1:$P")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" approved
  equals "$(field "$out" approved)" true
  equals "$(field "$out" cursor)" "2:$P"
  equals "$(field "$out" comments)" 0
}

@test "review-round takes its baseline from the first read and approves the send after it (example 1)" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=30
  TUICR_LIST_SEQUENCE="$(reads "$(session "$P" 0)" "$(session "$P" 1 "$SHA")")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" approved
  equals "$(field "$out" approved)" true
  equals "$(field "$out" cursor)" "1:$P"
  equals "$(field "$out" head_sha)" "$SHA"
  equals "$(field "$out" comments)" 0
}

@test "review-round reports the comments sent in the first release after the baseline read (example 2)" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=30
  TUICR_LIST_SEQUENCE="$(reads "$(session "$P" 0)" "$(session "$P" 1)")"
  export TUICR_LIST_SEQUENCE
  TUICR_COMMENTS_JSON="$(comments_released_in 1 1)"
  export TUICR_COMMENTS_JSON
  rc=0; out="$(round '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" comments
  equals "$(field "$out" approved)" false
  equals "$(field "$out" comments)" 2
  equals "$(field "$out" cursor)" "1:$P"
}

@test "review-round re-baselines on a new session file and approves the send in it (example 7)" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=30
  TUICR_LIST_SEQUENCE="$(reads "$(session "$Q" 0)" "$(session "$Q" 1 "$SHA")")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round "3:$P")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" approved
  equals "$(field "$out" approved)" true
  equals "$(field "$out" cursor)" "1:$Q"
  equals "$(field "$out" head_sha)" "$SHA"
}

@test "review-round reports none with the baseline as its cursor when no send arrives before the deadline (example 5)" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  TUICR_LIST_SEQUENCE="$(session "$P" 3)"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" approved)" false
  equals "$(field "$out" cursor)" "3:$P"
  equals "$(field "$out" comments)" 0
  equals "$(field "$out" head_sha)" ""
  contains "$(field "$out" reason)" "no send arrived within"
}

@test "review-round does not approve a send on a head other than the pull request's (example 11)" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  TUICR_LIST_SEQUENCE="$(reads "$(session "$P" 0)" "$(session "$P" 1 "$OTHER")")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" approved)" false
  equals "$(field "$out" cursor)" "1:$P"
  equals "$(field "$out" head_sha)" ""
  contains "$(field "$out" reason)" "head"
  contains "$(field "$out" reason)" "$OTHER"
}

@test "review-round does not approve a send tuicr reports with a null head_sha (example 12)" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  TUICR_LIST_SEQUENCE="$(reads "$(session "$P" 0)" "$(session "$P" 1)")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" approved)" false
  equals "$(field "$out" cursor)" "1:$P"
  contains "$(field "$out" reason)" "head_sha"
}

@test "review-round does not approve a send whose session carries no head_sha key" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  TUICR_LIST_SEQUENCE="$(reads "$(session "$P" 0)" "$(session "$P" 1 missing)")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" cursor)" "1:$P"
  contains "$(field "$out" reason)" "head_sha"
}

@test "review-round judges a new session file's releases from release 0, so a send already in it approves (example 8)" {
  TUICR_LIST_SEQUENCE="$(session "$Q" 1 "$SHA")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round "3:$P")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" approved
  equals "$(field "$out" approved)" true
  equals "$(field "$out" cursor)" "1:$Q"
  equals "$(field "$out" head_sha)" "$SHA"
}

@test "review-round does not approve a quit without a send (example 14)" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  TUICR_LIST_SEQUENCE="$(session "$P" 0 "$SHA")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" approved)" false
  equals "$(field "$out" cursor)" "0:$P"
}

@test "review-round reports none with an empty cursor, naming the session, when tuicr never has one (example 9)" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  export TUICR_LIST_SEQUENCE='[]'
  rc=0; out="$(round '' 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" approved)" false
  equals "$(field "$out" cursor)" ""
  contains "$(field "$out" reason)" "session"
  is_empty "$(cat "$STUB_BIN/err")"
}

@test "review-round keeps polling through a tuicr that exits 1, then reports none (example 10)" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  export TUICR_LIST_SEQUENCE=FAIL
  rc=0; out="$(round '' 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" approved)" false
  equals "$(field "$out" cursor)" ""
  contains "$(field "$out" reason)" "stub review list configured to fail"
  lacks "$(cat "$CALL_LOG")" "terminal create"
  is_empty "$(cat "$STUB_BIN/err")"
}

@test "review-round keeps polling through a tuicr that exits 1 mid-round, then reports none naming it" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  TUICR_LIST_SEQUENCE="$(reads "$(session "$P" 0)" FAIL)"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '' 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" cursor)" "0:$P"
  contains "$(field "$out" reason)" "stub review list configured to fail"
  is_empty "$(cat "$STUB_BIN/err")"
}

@test "review-round never takes a failed first read as no session, so the releases it hid approve nothing" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  TUICR_LIST_SEQUENCE="$(reads FAIL "$(session "$P" 2 "$SHA")")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" approved)" false
  equals "$(field "$out" cursor)" "2:$P"
}

@test "review-round never takes a first read it cannot parse as no session, so the releases it hid approve nothing" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  TUICR_LIST_SEQUENCE="$(reads 'not json' "$(session "$P" 2 "$SHA")")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" approved)" false
  equals "$(field "$out" cursor)" "2:$P"
}

@test "review-round keeps polling through a tuicr that prints no JSON, then reports none (example 10)" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  export TUICR_LIST_SEQUENCE='not json'
  rc=0; out="$(round '' 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" approved)" false
  equals "$(field "$out" cursor)" ""
  contains "$(field "$out" reason)" "cannot read the tuicr review list"
  lacks "$(cat "$CALL_LOG")" "terminal create"
  is_empty "$(cat "$STUB_BIN/err")"
}

@test "review-round keeps polling through a failed gh read and judges the send once gh answers" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=5
  export GH_PR_VIEW_STATES="FAIL OPEN"
  TUICR_LIST_SEQUENCE="$(reads "$(session "$P" 0)" "$(session "$P" 1 "$SHA")")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '' 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" approved
  equals "$(field "$out" cursor)" "1:$P"
  is_empty "$(cat "$STUB_BIN/err")"
}

# A head gh leaves empty would match the empty head of a send tuicr reports
# with head_sha null, and approve it.
@test "review-round judges nothing while gh reports no head, and reports none naming it" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  export GH_PR_HEAD_OID=''
  TUICR_LIST_SEQUENCE="$(reads "$(session "$P" 0)" "$(session "$P" 1)")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '' 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" approved)" false
  equals "$(field "$out" head_sha)" ""
  equals "$(field "$out" cursor)" "0:$P"
  contains "$(field "$out" reason)" "reported no state and head"
  is_empty "$(cat "$STUB_BIN/err")"
}

@test "review-round reports none naming gh's failure when gh never answers" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  export GH_PR_VIEW_STATES=FAIL
  TUICR_LIST_SEQUENCE="$(session "$P" 3 "$SHA")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round "2:$P" 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" approved)" false
  equals "$(field "$out" cursor)" "2:$P"
  contains "$(field "$out" reason)" "gh pr view 42 -R owner/repo failed"
  contains "$(field "$out" reason)" "stub pr view configured to fail"
  is_empty "$(cat "$STUB_BIN/err")"
}

@test "review-round exits 1 naming the state when the pull request is no longer open (example 13)" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  export GH_PR_VIEW_STATES=CLOSED
  TUICR_LIST_SEQUENCE="$(session "$P" 0)"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '' 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "CLOSED"
  contains "$(cat "$STUB_BIN/err")" "pull request 42 is CLOSED"
}

@test "review-round never approves a send whose comments tuicr fails to print" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  TUICR_LIST_SEQUENCE="$(session "$P" 3 "$SHA")"
  export TUICR_LIST_SEQUENCE
  export TUICR_COMMENTS_EXIT=1
  rc=0; out="$(round "2:$P" 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" approved)" false
  equals "$(field "$out" cursor)" "2:$P"
  contains "$(field "$out" reason)" "stub review comments configured to fail"
  is_empty "$(cat "$STUB_BIN/err")"
}

@test "review-round never approves a send whose comments tuicr prints as no JSON" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  TUICR_LIST_SEQUENCE="$(session "$P" 3 "$SHA")"
  export TUICR_LIST_SEQUENCE
  export TUICR_COMMENTS_JSON='not json'
  rc=0; out="$(round "2:$P" 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" approved)" false
  equals "$(field "$out" cursor)" "2:$P"
  contains "$(field "$out" reason)" "cannot read the tuicr comments"
  is_empty "$(cat "$STUB_BIN/err")"
}

# A cursor split anywhere else would name a path tuicr never reports, and a
# path the baseline does not name has every release judged, approving here.
@test "review-round splits a cursor on its first colon, so the path keeps its spaces and colons" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  path="/state/review sessions/pr:42.json"
  TUICR_LIST_SEQUENCE="$(session "$path" 2 "$SHA")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round "2:$path")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" cursor)" "2:$path"
}

@test "review-round sleeps 15 seconds between passes by default" {
  unset SLICE_WAVE_REVIEW_POLL_SECONDS
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=30
  # shellcheck disable=SC2016 # The stub expands $CALL_LOG when it runs, not here.
  printf '#!/bin/bash\nprintf "sleep\\t%%s\\n" "$*" >> "$CALL_LOG"\n' > "$STUB_BIN/sleep"
  chmod +x "$STUB_BIN/sleep"
  TUICR_LIST_SEQUENCE="$(reads "$(session "$P" 0)" "$(session "$P" 0)" "$(session "$P" 1 "$SHA")")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" approved
  equals "$(grep '^sleep' "$CALL_LOG")" "$(printf 'sleep\t15')"
}

@test "review-round exits 2 and calls nothing when a delivered round lacks a pull request, a repository or a readable cursor" {
  for bad in "--pr 0 --repo owner/repo --since ''" "--pr abc --repo owner/repo --since ''" \
    "--pr 42 --repo '' --since ''" "--pr 42 --repo owner/repo --since $P" \
    "--pr 42 --repo owner/repo --since x:$P" "--pr 42 --repo owner/repo --since 1x:$P"; do
    eval "set -- $bad"
    rc=0; out="$(review_round --bead demo-1 --delivered true "$@" 2>"$STUB_BIN/err")" || rc=$?
    equals "$bad $rc" "$bad 2"
    is_empty "$out"
    contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  done
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-round opens the tab in the registered main checkout, pointed at the pull request, without focus" {
  main="$(cd "$REPO" && pwd -P)"
  ORCA_REPO_LIST_JSON="$(repos "$main")"
  export ORCA_REPO_LIST_JSON
  approving_session
  rc=0; out="$(round "2:$P")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" approved
  contains "$(cat "$CALL_LOG")" "$(printf 'orca\tterminal list --json --include-visual-layouts')"
  create="$(grep 'terminal create' "$CALL_LOG")"
  contains "$create" "--worktree path:$main "
  contains "$create" "--title review demo-1 #42 "
  contains "$create" "--command tuicr pr owner/repo#42 "
  lacks "$create" "--focus"
  lacks "$(cat "$CALL_LOG")" "repo add"
}

@test "review-round registers an unregistered main checkout with Orca before opening the tab in it" {
  main="$(cd "$REPO" && pwd -P)"
  approving_session
  rc=0; out="$(round "2:$P")" || rc=$?
  equals "$rc" 0
  equals "$(grep -E '^orca	(repo add|terminal create)' "$CALL_LOG" | cut -f2 | cut -d' ' -f1-4)" \
    "$(printf 'repo add --path %s\nterminal create --worktree path:%s' "$main" "$main")"
  equals "$(grep 'repo add' "$CALL_LOG")" "$(printf 'orca\trepo add --path %s --json' "$main")"
}

@test "review-round treats a checkout Orca registered under a symlinked spelling as registered" {
  ln -s "$REPO" "$STUB_BIN/link"
  ORCA_REPO_LIST_JSON="$(repos "$STUB_BIN/link")"
  export ORCA_REPO_LIST_JSON
  approving_session
  rc=0; out="$(round "2:$P")" || rc=$?
  equals "$rc" 0
  lacks "$(cat "$CALL_LOG")" "repo add"
  contains "$(grep 'terminal create' "$CALL_LOG")" "--worktree path:$STUB_BIN/link "
}

@test "review-round registers the main checkout, not the linked worktree it runs in" {
  main="$(cd "$REPO" && pwd -P)"
  git -C "$REPO" worktree add --quiet "$STUB_BIN/wt" -b slice/demo-1
  approving_session
  rc=0; out="$(cd "$STUB_BIN/wt" && "$HELPER" review-round --bead demo-1 --delivered true \
    --pr 42 --repo owner/repo --since "2:$P")" || rc=$?
  equals "$rc" 0
  equals "$(grep 'repo add' "$CALL_LOG")" "$(printf 'orca\trepo add --path %s --json' "$main")"
}

@test "review-round opens no second tab when a nested layout already holds one of its title" {
  ORCA_TERMINAL_LIST_JSON="$(layouts '[
    {"worktreePath": "/other", "root": {"type": "group", "tabs": [{"tabId": "t0", "title": "shell"}]}},
    {"worktreePath": "/main", "root": {"type": "split", "children": [
      {"type": "group", "tabs": [{"tabId": "t1", "title": "notes"}]},
      {"type": "split", "children": [
        {"type": "group", "tabs": [{"tabId": "t2", "title": "review demo-1 #42"}]}]}]}}]')"
  export ORCA_TERMINAL_LIST_JSON
  approving_session
  rc=0; out="$(round "2:$P")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" approved
  lacks "$(cat "$CALL_LOG")" "repo add"
  lacks "$(cat "$CALL_LOG")" "terminal create"
}

@test "review-round opens the tab when a layout's tab titles are null and none matches" {
  ORCA_TERMINAL_LIST_JSON="$(layouts '[
    {"worktreePath": "/main", "root": {"type": "group", "tabs": [
      {"tabId": "t1", "title": null}, {"tabId": "t2"}, {"tabId": "t3", "title": "review demo-1 #4"}]}}]')"
  export ORCA_TERMINAL_LIST_JSON
  approving_session
  rc=0; out="$(round "2:$P" 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 0
  equals "$(grep -c 'terminal create' "$CALL_LOG")" 1
  is_empty "$(cat "$STUB_BIN/err")"
}

# Asserts review-round ended on an Orca failure: exit 1, nothing on stdout,
# orca's own message on stderr, and review never started.
assert_orca_failure() {
  rc=0; out="$(round "2:$P" 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "$1"
  lacks "$(cut -f1 "$CALL_LOG")" tuicr
}

@test "review-round exits 1 with orca's message and no review when terminal create fails" {
  export ORCA_TERMINAL_CREATE_EXIT=1
  approving_session
  assert_orca_failure "orca: stub terminal create configured to fail"
}

@test "review-round exits 1 with orca's message and no review when repo add fails" {
  export ORCA_REPO_ADD_EXIT=1
  approving_session
  assert_orca_failure "orca: stub repo add configured to fail"
  lacks "$(cat "$CALL_LOG")" "terminal create"
}

@test "review-round exits 1 with orca's report and no review when the tab lands in the background" {
  export ORCA_TERMINAL_CREATE_SURFACE=background
  approving_session
  assert_orca_failure '"surface":"background"'
}

@test "review-round exits 1 with orca's message and no review when terminal list reports ok false" {
  export ORCA_TERMINAL_LIST_JSON='{"ok":false,"error":{"message":"orca is not running"}}'
  approving_session
  assert_orca_failure "orca is not running"
  lacks "$(cat "$CALL_LOG")" "terminal create"
}

@test "review-round exits 1 with orca's message and no review when repo list fails" {
  export ORCA_REPO_LIST_EXIT=1
  approving_session
  assert_orca_failure "orca: stub repo list configured to fail"
  lacks "$(cat "$CALL_LOG")" "terminal create"
}

# A lost baseline would judge the returning session from release 0 and
# approve the releases it held before the tab opened.
@test "review-round keeps its baseline through a read where the session has disappeared" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  TUICR_LIST_SEQUENCE="$(reads "$(session "$P" 2 "$SHA")" '[]' "$(session "$P" 2 "$SHA")")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" approved)" false
  equals "$(field "$out" cursor)" "2:$P"
}

@test "review-round judges the first session seen after none from release 0, so a send already in it approves" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=30
  TUICR_LIST_SEQUENCE="$(reads '[]' '[]' "$(session "$P" 1 "$SHA")" "$(session "$P" 2 "$SHA")")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" approved
  equals "$(field "$out" cursor)" "1:$P"
}

# The engineer sends before the round's first poll after the tab opens, so
# the first session the round sees already holds the send.
@test "review-round approves a first-round send made before its first poll, snapshotting before the tab opens" {
  TUICR_LIST_SEQUENCE="$(reads '[]' "$(session "$P" 1 "$SHA")")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" approved
  equals "$(field "$out" approved)" true
  equals "$(field "$out" cursor)" "1:$P"
  equals "$(field "$out" head_sha)" "$SHA"
  equals "$(grep -E '^(tuicr	review list|orca	terminal create)' "$CALL_LOG" | cut -f1 | head -n 2 | tr '\n' ' ')" "tuicr orca "
}

@test "review-round keeps a session that predates the tab at its count, so its old sends approve nothing" {
  export SLICE_WAVE_REVIEW_WAIT_SECONDS=2
  TUICR_LIST_SEQUENCE="$(session "$P" 2 "$SHA")"
  export TUICR_LIST_SEQUENCE
  rc=0; out="$(round '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" none
  equals "$(field "$out" approved)" false
  equals "$(field "$out" cursor)" "2:$P"
}
