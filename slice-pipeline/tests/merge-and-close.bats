# Each @test runs in its own subshell, so the stub knobs a test exports are
# meant to stay local to it.
# shellcheck disable=SC2030,SC2031
load helpers/assert
load helpers/stubs

# `slice-wave merge` takes a green pull request to merged, confirmed by the
# forge, and `slice-wave close` then closes the bead and removes the run's
# worktree. Every external tool but git is a stub from helpers/stubs.bash,
# scripted per test.
HELPER="${BATS_TEST_DIRNAME}/../bin/slice-wave"

# The head commit review approved, which merge pins the forge to.
SHA=89abcdef0123456789abcdef0123456789abcdef

setup() {
  command -v jq >/dev/null || skip "no jq"

  # See slice-wave.bats: the developer's signing config would hang commits.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  STUB_BIN="$(mktemp -d)"
  export STUB_BIN
  export FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures/axi"
  install_stubs

  # No run may read the machine's real repos.json, and no poll may sleep.
  export XDG_CONFIG_HOME="$STUB_BIN/config"
  export SLICE_WAVE_MERGE_POLL_SECONDS=0 SLICE_WAVE_MERGE_DROP_GRACE_SECONDS=0

  OLD_PATH="$PATH"
  export PATH="$STUB_BIN:$PATH"

  REPO="$(mktemp -d)"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test \
    commit --quiet --allow-empty -m base
}

teardown() {
  export PATH="$OLD_PATH"
  rm -rf "$STUB_BIN" "$REPO"
}

merge() {
  ( cd "$REPO" && "$HELPER" merge "$@" )
}

field() {
  printf '%s' "$1" | jq -r ".$2"
}

# How many times merge read the pull request, through `gh pr view` or the
# GraphQL query the merge-queue strategy uses.
reads() {
  grep -c -e 'pr view' -e 'pullRequest(number' "$CALL_LOG"
}

@test "merge calls no tool and merges nothing when the slice was not approved in review" {
  rc=0; out="$(merge --approved false --head-sha '' --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "nothing was merged"
  contains "$(field "$out" reason)" "not approved in review"
  is_empty "$(cat "$CALL_LOG")"
}

@test "merge accepts the empty repo and zero PR validate reports for a slice review did not approve" {
  rc=0; out="$(merge --approved false --head-sha '' --pr 0 --repo '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "nothing was merged"
  is_empty "$(cat "$CALL_LOG")"
}

@test "merge exits 2 with the usage line when an approved slice has an empty --repo" {
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo '' 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  is_empty "$(cat "$CALL_LOG")"
}

@test "merge squashes when no repos.json exists and reports the merge the forge confirms" {
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  contains "$(cat "$CALL_LOG")" "$(printf 'gh\tpr merge 42 -R owner/repo --squash')"
  contains "$(grep 'pr merge' "$CALL_LOG")" "--match-head-commit $SHA"
  equals "$(field "$out" merged)" true
  equals "$(field "$out" strategy)" squash
  equals "$(field "$out" pr_url)" "https://github.com/owner/repo/pull/42"
}

@test "merge enqueues with no strategy flag when repos.json puts the repo on a merge queue" {
  mkdir -p "$XDG_CONFIG_HOME/slice-pipeline"
  printf '{"owner/repo":{"merge_queue":true}}\n' > "$XDG_CONFIG_HOME/slice-pipeline/repos.json"
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(grep 'pr merge' "$CALL_LOG")" "$(printf 'gh\tpr merge 42 -R owner/repo --match-head-commit %s' "$SHA")"
  equals "$(field "$out" strategy)" merge-queue
  equals "$(field "$out" merged)" true
  equals "$(field "$out" pr_url)" "https://github.com/owner/repo/pull/42"
  contains "$(grep 'pullRequest(number' "$CALL_LOG")" "-f owner=owner -f name=repo -F number=42"
}

@test "merge squashes when repos.json names only other repositories" {
  mkdir -p "$XDG_CONFIG_HOME/slice-pipeline"
  printf '{"other/repo":{"merge_queue":true}}\n' > "$XDG_CONFIG_HOME/slice-pipeline/repos.json"
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(grep 'pr merge' "$CALL_LOG")" "$(printf 'gh\tpr merge 42 -R owner/repo --squash --match-head-commit %s' "$SHA")"
  equals "$(field "$out" strategy)" squash
}

@test "merge squashes a repository repos.json lists with merge_queue false" {
  mkdir -p "$XDG_CONFIG_HOME/slice-pipeline"
  printf '{"owner/repo":{"merge_queue":false}}\n' > "$XDG_CONFIG_HOME/slice-pipeline/repos.json"
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(grep 'pr merge' "$CALL_LOG")" "$(printf 'gh\tpr merge 42 -R owner/repo --squash --match-head-commit %s' "$SHA")"
  equals "$(field "$out" strategy)" squash
}

@test "merge merges nothing and names repos.json when jq cannot parse it" {
  mkdir -p "$XDG_CONFIG_HOME/slice-pipeline"
  printf 'not json\n' > "$XDG_CONFIG_HOME/slice-pipeline/repos.json"
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "repos.json"
  lacks "$(cat "$CALL_LOG")" "pr merge"
}

@test "merge reports gh's refusal after one read when the merge fails and the PR stays open" {
  export GH_PR_MERGE_EXIT=1 GH_PR_VIEW_STATES=OPEN
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "Pull request is not mergeable"
  equals "$(reads)" 1
}

@test "merge polls an open PR until the forge reports it merged" {
  export GH_PR_VIEW_STATES="OPEN OPEN MERGED"
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" true
  equals "$(reads)" 3
}

queue_repo() {
  mkdir -p "$XDG_CONFIG_HOME/slice-pipeline"
  printf '{"owner/repo":{"merge_queue":true}}\n' > "$XDG_CONFIG_HOME/slice-pipeline/repos.json"
}

@test "merge fails once a re-read confirms the merge queue dropped a PR it had queued" {
  queue_repo
  export GH_PR_VIEW_STATES="OPEN:queued OPEN OPEN MERGED"
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "merge queue dropped"
  equals "$(reads)" 3
}

@test "merge reports merged when the re-read after an unqueued read finds the PR merged" {
  queue_repo
  export GH_PR_VIEW_STATES="OPEN:queued OPEN MERGED"
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" true
  equals "$(reads)" 3
}

@test "merge disables auto-merge and dequeues a PR still queued at the time limit" {
  queue_repo
  export SLICE_WAVE_MERGE_LIMIT_SECONDS=0 GH_PR_VIEW_STATES=OPEN:queued
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "dequeued at the deadline"
  contains "$(cat "$CALL_LOG")" "$(printf 'gh\tpr merge 42 -R owner/repo --disable-auto')"
  contains "$(grep dequeuePullRequest "$CALL_LOG")" "id=PR_stub42"
  equals "$(reads)" 2
}

@test "merge only disables auto-merge on a queue PR not yet queued at the time limit" {
  queue_repo
  export SLICE_WAVE_MERGE_LIMIT_SECONDS=0 GH_PR_VIEW_STATES=OPEN
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "dequeued at the deadline"
  contains "$(cat "$CALL_LOG")" "--disable-auto"
  lacks "$(cat "$CALL_LOG")" dequeuePullRequest
}

@test "merge reports merged when the read after the deadline dequeue finds the PR merged" {
  queue_repo
  export SLICE_WAVE_MERGE_LIMIT_SECONDS=0 GH_PR_VIEW_STATES="OPEN:queued MERGED"
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" true
  is_empty "$(field "$out" reason)"
}

@test "merge names a dequeue gh refused at the time limit" {
  queue_repo
  export SLICE_WAVE_MERGE_LIMIT_SECONDS=0 GH_PR_VIEW_STATES=OPEN:queued GH_API_GRAPHQL_EXIT=1
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "could not dequeue pull request 42"
  contains "$(field "$out" reason)" "Could not dequeue pull request"
  lacks "$(field "$out" reason)" "dequeued at the deadline"
}

@test "merge keeps polling a queue PR waiting on checks and then sitting in the queue" {
  queue_repo
  export GH_PR_VIEW_STATES="OPEN OPEN:queued OPEN:queued MERGED"
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" true
  equals "$(reads)" 4
}

@test "merge ignores the merge queue for a squashed PR" {
  export GH_PR_VIEW_STATES="OPEN:queued OPEN MERGED"
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" true
  equals "$(reads)" 3
}

@test "merge reports a PR the forge closed without merging" {
  export GH_PR_VIEW_STATES=CLOSED
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "closed"
}

@test "merge reports gh's refusal with a PR the forge closed" {
  export GH_PR_MERGE_EXIT=1 GH_PR_VIEW_STATES=CLOSED
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "closed"
  contains "$(field "$out" reason)" "Pull request is not mergeable"
}

@test "merge names gh's read error when no read succeeds before the time limit" {
  export SLICE_WAVE_MERGE_LIMIT_SECONDS=0 GH_PR_VIEW_STATES=FAIL
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "could not read pull request 42 state"
  contains "$(field "$out" reason)" "stub pr view configured to fail"
}

@test "merge names a state the forge reports outside merged, closed and open" {
  export SLICE_WAVE_MERGE_LIMIT_SECONDS=0 GH_PR_VIEW_STATES=UNKNOWN
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "unexpected state 'UNKNOWN'"
}

@test "merge gives up on a PR still open when the time limit has passed" {
  export SLICE_WAVE_MERGE_LIMIT_SECONDS=0 GH_PR_VIEW_STATES=OPEN
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "still open"
  lacks "$(cat "$CALL_LOG")" "--disable-auto"
}

@test "merge trusts the forge over a failed merge command when the PR merged" {
  export GH_PR_MERGE_EXIT=1 GH_PR_VIEW_STATES=MERGED
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" true
}

@test "merge reads again after a failed read" {
  export GH_PR_VIEW_STATES="FAIL MERGED"
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" true
}

@test "merge calls no tool when an approved slice names no pull request" {
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 0 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "no pull request"
  is_empty "$(cat "$CALL_LOG")"
}

@test "merge exits 2 with the usage line when --repo is missing" {
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr 42 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  is_empty "$(cat "$CALL_LOG")"
}

@test "merge exits 2 naming --approved when it is neither true nor false" {
  rc=0; out="$(merge --approved maybe --head-sha "$SHA" --pr 42 --repo '' 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "--approved must be true or false, not 'maybe'"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  is_empty "$(cat "$CALL_LOG")"
}

@test "merge exits 2 with the usage line on --delivered, which --approved replaced" {
  rc=0; out="$(merge --delivered true --pr 42 --repo owner/repo 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "unknown flag --delivered"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  is_empty "$(cat "$CALL_LOG")"
}

@test "merge exits 2 with the usage line and calls nothing when an approved slice's --head-sha is not 40 lowercase hex" {
  for bad in '' abc "${SHA:0:39}" "$(printf '%s' "$SHA" | tr a-f A-F)" "${SHA}0"; do
    rc=0; out="$(merge --approved true --head-sha "$bad" --pr 42 --repo owner/repo 2>"$STUB_BIN/err")" || rc=$?
    equals "$rc" 2
    is_empty "$out"
    contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  done
  is_empty "$(cat "$CALL_LOG")"
}

@test "merge exits 2 with the usage line when --pr is not a number" {
  rc=0; out="$(merge --approved true --head-sha "$SHA" --pr abc --repo owner/repo 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  is_empty "$(cat "$CALL_LOG")"
}

# Runs close from the directory $1, the rest of the arguments passed on.
close_in() {
  local dir="$1"
  shift
  ( cd "$dir" && "$HELPER" close "$@" )
}

@test "close closes the bead and leaves the main worktree alone" {
  rc=0; out="$(close_in "$REPO" --bead foo --beads-dir /tmp/beads-demo \
    --pr-url https://github.com/owner/repo/pull/42)" || rc=$?
  equals "$rc" 0
  equals "$(cat "$BD_LOG")" \
    "$(printf '/tmp/beads-demo\tclose foo --reason merged in https://github.com/owner/repo/pull/42')"
  equals "$(printf '%s' "$out" | jq -c .)" '{"closed":true,"worktree_removed":false,"reason":""}'
  [ -d "$REPO" ] || { echo "the main worktree was removed" >&2; exit 1; }
}

# Adds the linked worktree $WT on slice/foo, holding an untracked file the
# way a run's build output would. It lives under $STUB_BIN, so teardown
# reaps it.
add_linked_worktree() {
  WT="$STUB_BIN/wt"
  git -C "$REPO" worktree add --quiet "$WT" -b slice/foo
  : > "$WT/build-output.log"
}

@test "close removes the run's linked worktree, untracked files and all, once the bead closes" {
  add_linked_worktree
  rc=0; out="$(close_in "$WT" --bead foo --beads-dir /tmp/beads-demo \
    --pr-url https://github.com/owner/repo/pull/42)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" worktree_removed)" true
  [ ! -e "$WT" ] || { echo "the worktree still exists" >&2; exit 1; }
  lacks "$(git -C "$REPO" worktree list)" "$(cd "$STUB_BIN" && pwd -P)/wt"
}

@test "close exits 0 with the bead closed when git cannot remove the worktree" {
  add_linked_worktree
  git -C "$REPO" worktree lock "$WT"
  rc=0; out="$(close_in "$WT" --bead foo --beads-dir /tmp/beads-demo \
    --pr-url https://github.com/owner/repo/pull/42)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" closed)" true
  equals "$(field "$out" worktree_removed)" false
  contains "$(field "$out" reason)" "could not remove worktree"
  [ -d "$WT" ] || { echo "the worktree was removed" >&2; exit 1; }
}

@test "close exits 1 and keeps the worktree when the tracker refuses to close the bead" {
  add_linked_worktree
  export BD_EXIT_CODE=1
  rc=0; out="$(close_in "$WT" --bead foo --beads-dir /tmp/beads-demo \
    --pr-url https://github.com/owner/repo/pull/42 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "tracker refused to close"
  contains "$(cat "$STUB_BIN/err")" "bd: stub configured to fail"
  [ -d "$WT" ] || { echo "the worktree was removed" >&2; exit 1; }
}

@test "close exits 2 without touching the tracker when --pr-url is missing" {
  rc=0; out="$(close_in "$REPO" --bead foo --beads-dir /tmp/beads-demo 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  is_empty "$(cat "$BD_LOG")"
}
