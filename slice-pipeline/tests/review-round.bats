# Each @test runs in its own subshell, so the stub knobs a test exports are
# meant to stay local to it.
# shellcheck disable=SC2030,SC2031
load helpers/assert
load helpers/stubs

# `slice-wave review-round` opens the review tab for a delivered slice's pull
# request and hands the review gate its question, or turns the gate's last
# answer into the approval merge reads. Every external tool but git is a stub
# from helpers/stubs.bash, scripted per test.
HELPER="${BATS_TEST_DIRNAME}/../bin/slice-wave"

# The pull request's head (the gh stub's default headRefOid) and some other
# commit.
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

  export GH_PR_VIEW_STATES=OPEN
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

# One delivered round for bead demo-1 on owner/repo#42 in run run-1, after
# the gate answered $1 with text $2, the last round having shown head $3.
round() {
  review_round --bead demo-1 --delivered true --pr 42 --repo owner/repo --run run-1 \
    --answer "${1:-}" --answer-text "${2:-}" --shown-head "${3:-}"
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

@test "review-round reports undelivered and calls nothing when the slice was not delivered" {
  rc=0; out="$(review_round --bead demo-1 --delivered false --pr 0 --repo '' --run run-1 --answer '' --answer-text '' --shown-head '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" undelivered
  equals "$(field "$out" approved)" false
  equals "$(field "$out" head_sha)" ""
  equals "$(field "$out" question)" ""
  contains "$(field "$out" reason)" "not delivered"
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-round exits 2 with the usage line and calls nothing on an unknown flag" {
  rc=0; out="$(review_round --bead demo-1 --delivered false --pr 0 --repo '' --run run-1 --answer '' --answer-text '' --shown-head '' --since '' 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "unknown flag --since"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-round exits 2 with the usage line and calls nothing when --delivered is neither true nor false" {
  rc=0; out="$(review_round --bead demo-1 --delivered maybe --pr 42 --repo owner/repo --run run-1 --answer '' --answer-text '' --shown-head '' 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "--delivered must be true or false, not 'maybe'"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-round exits 2 with the usage line and calls nothing when any of its eight flags is missing" {
  for missing in --bead --delivered --pr --repo --run --answer --answer-text --shown-head; do
    args=()
    for pair in "--bead demo-1" "--delivered false" "--pr 0" "--repo owner/repo" "--run run-1" \
      "--answer approved" "--answer-text $SHA" "--shown-head $SHA"; do
      [ "${pair%% *}" = "$missing" ] || args+=("${pair%% *}" "${pair#* }")
    done
    rc=0; out="$(review_round "${args[@]}" 2>"$STUB_BIN/err")" || rc=$?
    equals "$missing $rc" "$missing 2"
    is_empty "$out"
    contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  done
  is_empty "$(cat "$CALL_LOG")"
}

# The repository and run id go into the review tab's shell command, so only
# their plain shapes pass.
@test "review-round exits 2 and calls nothing when a delivered round lacks a pull request, a plain repository, a run id or a known answer" {
  for bad in "--pr 0 --repo owner/repo --run run-1 --answer ''" \
    "--pr abc --repo owner/repo --run run-1 --answer ''" \
    "--pr 42 --repo '' --run run-1 --answer ''" \
    "--pr 42 --repo 'owner/repo;touch x' --run run-1 --answer ''" \
    "--pr 42 --repo owner --run run-1 --answer ''" \
    "--pr 42 --repo owner/repo --run '' --answer ''" \
    "--pr 42 --repo owner/repo --run 'run 1' --answer ''" \
    "--pr 42 --repo owner/repo --run run-1 --answer yes"; do
    eval "set -- $bad"
    rc=0; out="$(review_round --bead demo-1 --delivered true "$@" --answer-text '' --shown-head '' 2>"$STUB_BIN/err")" || rc=$?
    equals "$bad $rc" "$bad 2"
    is_empty "$out"
    contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  done
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-round opens the review tab and hands the gate a question naming the pull request's head" {
  rc=0; out="$(round)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" waiting
  equals "$(field "$out" approved)" false
  equals "$(field "$out" head_sha)" "$SHA"
  contains "$(field "$out" question)" "owner/repo#42 at $SHA"
  contains "$(field "$out" question)" "'review demo-1 #42'"
  equals "$(field "$out" reason)" ""
  equals "$(grep -c 'terminal create' "$CALL_LOG")" 1
}

@test "review-round waits again after the gate took comments" {
  rc=0; out="$(round comments "2 comments sent in release 3" "$OTHER")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" waiting
  equals "$(field "$out" head_sha)" "$SHA"
  contains "$(field "$out" reason)" "comments were sent"
}

@test "review-round approves the head the gate's answer names, calling nothing" {
  rc=0; out="$(round approved "$OTHER" "$SHA")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" approved
  equals "$(field "$out" approved)" true
  equals "$(field "$out" head_sha)" "$OTHER"
  equals "$(field "$out" question)" ""
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-round approves the head the last question showed when the approval's text names no commit" {
  for text in "" "looks good"; do
    rc=0; out="$(round approved "$text" "$SHA")" || rc=$?
    equals "$text $rc" "$text 0"
    equals "$(field "$out" outcome)" approved
    equals "$(field "$out" head_sha)" "$SHA"
  done
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-round exits 1 when an approval names no commit and the last question showed none" {
  rc=0; out="$(round approved "" "" 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "nothing safe to merge"
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-round exits 1 naming the state and opens no tab when the pull request is no longer open" {
  export GH_PR_VIEW_STATES=MERGED
  rc=0; out="$(round 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "pull request 42 is MERGED"
  lacks "$(cut -f1 "$CALL_LOG")" orca
}

@test "review-round exits 1 naming gh's failure and opens no tab when gh cannot read the pull request" {
  export GH_PR_VIEW_STATES=FAIL
  rc=0; out="$(round 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "gh pr view 42 -R owner/repo failed"
  lacks "$(cut -f1 "$CALL_LOG")" orca
}

@test "review-round exits 1 when gh reports no head" {
  export GH_PR_HEAD_OID=''
  rc=0; out="$(round 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 1
  contains "$(cat "$STUB_BIN/err")" "reported no state and head"
}

@test "review-round opens the tab in the registered main checkout, pointed at the pull request, without focus" {
  main="$(cd "$REPO" && pwd -P)"
  ORCA_REPO_LIST_JSON="$(repos "$main")"
  export ORCA_REPO_LIST_JSON
  rc=0; out="$(round)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" waiting
  contains "$(cat "$CALL_LOG")" "$(printf 'orca\tterminal list --json --include-visual-layouts')"
  create="$(grep 'terminal create' "$CALL_LOG")"
  contains "$create" "--worktree path:$main "
  contains "$create" "--title review demo-1 #42 "
  self="$(cd "$(dirname "$HELPER")" && pwd -P)/slice-wave"
  contains "$create" "--command nohup $self review-watch --run run-1 --pr 42 --repo owner/repo >/dev/null 2>&1 & exec tuicr pr owner/repo#42 "
  lacks "$create" "--focus"
  lacks "$(cat "$CALL_LOG")" "repo add"
}

@test "review-round registers an unregistered main checkout with Orca before opening the tab in it" {
  main="$(cd "$REPO" && pwd -P)"
  rc=0; out="$(round)" || rc=$?
  equals "$rc" 0
  equals "$(grep -E '^orca	(repo add|terminal create)' "$CALL_LOG" | cut -f2 | cut -d' ' -f1-4)" \
    "$(printf 'repo add --path %s\nterminal create --worktree path:%s' "$main" "$main")"
  equals "$(grep 'repo add' "$CALL_LOG")" "$(printf 'orca\trepo add --path %s --json' "$main")"
}

@test "review-round treats a checkout Orca registered under a symlinked spelling as registered" {
  ln -s "$REPO" "$STUB_BIN/link"
  ORCA_REPO_LIST_JSON="$(repos "$STUB_BIN/link")"
  export ORCA_REPO_LIST_JSON
  rc=0; out="$(round)" || rc=$?
  equals "$rc" 0
  lacks "$(cat "$CALL_LOG")" "repo add"
  contains "$(grep 'terminal create' "$CALL_LOG")" "--worktree path:$STUB_BIN/link "
}

@test "review-round registers the main checkout, not the linked worktree it runs in" {
  main="$(cd "$REPO" && pwd -P)"
  git -C "$REPO" worktree add --quiet "$STUB_BIN/wt" -b slice/demo-1
  rc=0; out="$(cd "$STUB_BIN/wt" && "$HELPER" review-round --bead demo-1 --delivered true \
    --pr 42 --repo owner/repo --run run-1 --answer '' --answer-text '' --shown-head '')" || rc=$?
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
  rc=0; out="$(round)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" waiting
  lacks "$(cat "$CALL_LOG")" "repo add"
  lacks "$(cat "$CALL_LOG")" "terminal create"
}

@test "review-round opens the tab when a layout's tab titles are null and none matches" {
  ORCA_TERMINAL_LIST_JSON="$(layouts '[
    {"worktreePath": "/main", "root": {"type": "group", "tabs": [
      {"tabId": "t1", "title": null}, {"tabId": "t2"}, {"tabId": "t3", "title": "review demo-1 #4"}]}}]')"
  export ORCA_TERMINAL_LIST_JSON
  rc=0; out="$(round 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 0
  equals "$(grep -c 'terminal create' "$CALL_LOG")" 1
  is_empty "$(cat "$STUB_BIN/err")"
}

# Asserts review-round ended on an Orca failure: exit 1, nothing on stdout
# and orca's own message on stderr.
assert_orca_failure() {
  rc=0; out="$(round 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "$1"
}

@test "review-round exits 1 with orca's message and no review when terminal create fails" {
  export ORCA_TERMINAL_CREATE_EXIT=1
  assert_orca_failure "orca: stub terminal create configured to fail"
}

@test "review-round exits 1 with orca's message and no review when repo add fails" {
  export ORCA_REPO_ADD_EXIT=1
  assert_orca_failure "orca: stub repo add configured to fail"
  lacks "$(cat "$CALL_LOG")" "terminal create"
}

@test "review-round exits 1 with orca's report and no review when the tab lands in the background" {
  export ORCA_TERMINAL_CREATE_SURFACE=background
  assert_orca_failure '"surface":"background"'
}

@test "review-round exits 1 with orca's message and no review when terminal list reports ok false" {
  export ORCA_TERMINAL_LIST_JSON='{"ok":false,"error":{"message":"orca is not running"}}'
  assert_orca_failure "orca is not running"
  lacks "$(cat "$CALL_LOG")" "terminal create"
}

@test "review-round exits 1 with orca's message and no review when repo list fails" {
  export ORCA_REPO_LIST_EXIT=1
  assert_orca_failure "orca: stub repo list configured to fail"
  lacks "$(cat "$CALL_LOG")" "terminal create"
}

# GitHub mode, for a machine with no Orca or tuicr: review-round starts a
# detached review-watch on the pull request's GitHub reviews instead of a
# tab. The watcher here finds the run completed and exits at once.
github_round() {
  SLICE_WAVE_REVIEW=github SLICE_WAVE_REVIEW_APPROVERS=trevor round "$@"
}

# True once the detached watcher has read the pull request's reviews and
# ended, waiting up to 5 seconds for it, so teardown never pulls its stubs
# from under it.
watcher_read_reviews() {
  local tries=0
  until grep -q $'^gh\tapi repos/owner/repo/pulls/42/reviews' "$CALL_LOG" &&
    grep -q "so the watch ends" "$XDG_STATE_HOME/slice-pipeline/review-run-1.log" 2>/dev/null; do
    [ "$tries" -lt 50 ] || return 1
    tries=$((tries + 1))
    sleep 0.1
  done
}

@test "review-round in GitHub mode starts a watcher instead of a tab and names the pull request's URL and head" {
  export XDG_STATE_HOME="$STUB_BIN/state" ARCHON_GET_SEQUENCE=completed SLICE_WAVE_REVIEW_POLL_SECONDS=0
  rc=0; out="$(github_round)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" waiting
  equals "$(field "$out" head_sha)" "$SHA"
  contains "$(field "$out" question)" "https://github.com/owner/repo/pull/42 at $SHA on GitHub"
  contains "$(field "$out" question)" "/approve"
  watcher_read_reviews
  is_empty "$(grep $'^orca\t' "$CALL_LOG")"
}

@test "review-round in GitHub mode approves the head the gate's answer names, calling nothing" {
  rc=0; out="$(github_round approved "$SHA" "$OTHER")" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" approved
  equals "$(field "$out" head_sha)" "$SHA"
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-round in GitHub mode exits 1 and calls nothing when no approver is set" {
  for approvers in "" " , "; do
    rc=0; out="$(SLICE_WAVE_REVIEW=github SLICE_WAVE_REVIEW_APPROVERS="$approvers" round 2>"$STUB_BIN/err")" || rc=$?
    equals "'$approvers' $rc" "'$approvers' 1"
    is_empty "$out"
    contains "$(cat "$STUB_BIN/err")" "needs SLICE_WAVE_REVIEW_APPROVERS"
  done
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-round exits 1 and calls nothing on an unknown review mode" {
  rc=0; out="$(SLICE_WAVE_REVIEW=gitlab round 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "must be tuicr or github, not 'gitlab'"
  is_empty "$(cat "$CALL_LOG")"
}

@test "review-round in GitHub mode reports undelivered with no approvers set, since there is nothing to review" {
  rc=0; out="$(SLICE_WAVE_REVIEW=github review_round --bead demo-1 --delivered false --pr 0 --repo '' --run run-1 --answer '' --answer-text '' --shown-head '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" outcome)" undelivered
  is_empty "$(cat "$CALL_LOG")"
}
