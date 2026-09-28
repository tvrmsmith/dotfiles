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
  export SLICE_WAVE_MERGE_POLL_SECONDS=0

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

@test "merge calls no tool and merges nothing when the slice was not delivered" {
  rc=0; out="$(merge --delivered false --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "nothing was merged"
  is_empty "$(cat "$CALL_LOG")"
}

@test "merge accepts the empty repo and zero PR validate reports for an undelivered slice" {
  rc=0; out="$(merge --delivered false --pr 0 --repo '')" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "nothing was merged"
  is_empty "$(cat "$CALL_LOG")"
}

@test "merge exits 2 with the usage line when a delivered slice has an empty --repo" {
  rc=0; out="$(merge --delivered true --pr 42 --repo '' 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  is_empty "$(cat "$CALL_LOG")"
}

@test "merge squashes when no repos.json exists and reports the merge the forge confirms" {
  rc=0; out="$(merge --delivered true --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  contains "$(cat "$CALL_LOG")" "$(printf 'gh\tpr merge 42 -R owner/repo --squash')"
  equals "$(field "$out" merged)" true
  equals "$(field "$out" strategy)" squash
  equals "$(field "$out" pr_url)" "https://github.com/owner/repo/pull/42"
}

@test "merge enqueues with no strategy flag when repos.json puts the repo on a merge queue" {
  mkdir -p "$XDG_CONFIG_HOME/slice-pipeline"
  printf '{"owner/repo":{"merge_queue":true}}\n' > "$XDG_CONFIG_HOME/slice-pipeline/repos.json"
  rc=0; out="$(merge --delivered true --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(grep 'pr merge' "$CALL_LOG")" "$(printf 'gh\tpr merge 42 -R owner/repo')"
  equals "$(field "$out" strategy)" merge-queue
}

@test "merge squashes when repos.json names only other repositories" {
  mkdir -p "$XDG_CONFIG_HOME/slice-pipeline"
  printf '{"other/repo":{"merge_queue":true}}\n' > "$XDG_CONFIG_HOME/slice-pipeline/repos.json"
  rc=0; out="$(merge --delivered true --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(grep 'pr merge' "$CALL_LOG")" "$(printf 'gh\tpr merge 42 -R owner/repo --squash')"
  equals "$(field "$out" strategy)" squash
}

@test "merge squashes a repository repos.json lists with merge_queue false" {
  mkdir -p "$XDG_CONFIG_HOME/slice-pipeline"
  printf '{"owner/repo":{"merge_queue":false}}\n' > "$XDG_CONFIG_HOME/slice-pipeline/repos.json"
  rc=0; out="$(merge --delivered true --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(grep 'pr merge' "$CALL_LOG")" "$(printf 'gh\tpr merge 42 -R owner/repo --squash')"
  equals "$(field "$out" strategy)" squash
}

@test "merge merges nothing and names repos.json when jq cannot parse it" {
  mkdir -p "$XDG_CONFIG_HOME/slice-pipeline"
  printf 'not json\n' > "$XDG_CONFIG_HOME/slice-pipeline/repos.json"
  rc=0; out="$(merge --delivered true --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "repos.json"
  lacks "$(cat "$CALL_LOG")" "pr merge"
}

@test "merge reports gh's refusal after one read when the merge fails and the PR stays open" {
  export GH_PR_MERGE_EXIT=1 GH_PR_VIEW_STATES=OPEN
  rc=0; out="$(merge --delivered true --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "Pull request is not mergeable"
  equals "$(grep -c 'pr view' "$CALL_LOG")" 1
}

@test "merge polls an open PR until the forge reports it merged" {
  export GH_PR_VIEW_STATES="OPEN OPEN MERGED"
  rc=0; out="$(merge --delivered true --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" true
  equals "$(grep -c 'pr view' "$CALL_LOG")" 3
}

@test "merge reports a PR the forge closed without merging" {
  export GH_PR_VIEW_STATES=CLOSED
  rc=0; out="$(merge --delivered true --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "closed"
}

@test "merge gives up on a PR still open when the time limit has passed" {
  export SLICE_WAVE_MERGE_LIMIT_SECONDS=0 GH_PR_VIEW_STATES=OPEN
  rc=0; out="$(merge --delivered true --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "still open"
}

@test "merge trusts the forge over a failed merge command when the PR merged" {
  export GH_PR_MERGE_EXIT=1 GH_PR_VIEW_STATES=MERGED
  rc=0; out="$(merge --delivered true --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" true
}

@test "merge reads again after a failed read" {
  export GH_PR_VIEW_STATES="FAIL MERGED"
  rc=0; out="$(merge --delivered true --pr 42 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" true
}

@test "merge calls no tool when a delivered slice names no pull request" {
  rc=0; out="$(merge --delivered true --pr 0 --repo owner/repo)" || rc=$?
  equals "$rc" 0
  equals "$(field "$out" merged)" false
  contains "$(field "$out" reason)" "no pull request"
  is_empty "$(cat "$CALL_LOG")"
}

@test "merge exits 2 with the usage line when --repo is missing" {
  rc=0; out="$(merge --delivered true --pr 42 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  is_empty "$(cat "$CALL_LOG")"
}

@test "merge exits 2 with the usage line when --delivered is neither true nor false" {
  rc=0; out="$(merge --delivered maybe --pr 42 --repo owner/repo 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  is_empty "$(cat "$CALL_LOG")"
}

@test "merge exits 2 with the usage line when --pr is not a number" {
  rc=0; out="$(merge --delivered true --pr abc --repo owner/repo 2>"$STUB_BIN/err")" || rc=$?
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
