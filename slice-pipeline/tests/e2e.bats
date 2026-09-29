load helpers/assert
load helpers/e2e-cleanup
load helpers/e2e-sandbox
load helpers/e2e-review

# The one suite that runs the real pipeline: a real GitHub target, this tree's
# workflow under the real engine, and a real model building a real bead. The
# other suites each stub out a layer (slice-wave.bats the engine, the
# fixtures the script, the wiring suite the model), so only this one shows
# that the nodes - claim, build, verify, validate, merge, close - hand off to
# each other for real, against a repository claim's own preflight checks
# actually have to accept.
#
# claim now refuses a target it cannot open pull requests on or that
# no-mistakes has never validated (see check_target_forge and
# check_target_no_mistakes in bin/slice-wave), so the scratch repo the old
# version of this suite built - a local bare origin, never run through
# `no-mistakes init` - no longer clears claim and cannot stand in for a real
# target. This version clones a real sandbox repository instead.
#
# Opt-in, because a run spends model tokens, pushes a branch, and opens and
# merges a pull request on the sandbox, and can go red on a bad model
# run rather than on broken code:
#
#   SLICE_E2E=1 SLICE_E2E_REPO=owner/name bats slice-pipeline/tests/e2e.bats
#
# SLICE_E2E_REPO names a GitHub repository (owner/name) you can push to and
# open pull requests on; the suite skips with a clear message when it is
# unset. It must be a sandbox kept only for this suite. setup_file refuses any
# target without a committed .slice-e2e-sandbox marker before it pushes or
# opens anything (see require_e2e_sandbox), since an unguarded run once merged
# into this project's own main. It clones that repository to scratch, runs
# `no-mistakes init` there so claim's preflight passes, then drives one small
# bead through the real pipeline: claim, a real model build, verify, a real
# no-mistakes validate drive against that repository's forge, a real merge,
# and close. A green run therefore leaves a merged pull request and its code
# on the target's default branch. The script and test file names carry the
# bead id, so a rerun against the same target never collides with an earlier
# run's merged files.
# Teardown closes any pull request still open on the slice branch, deletes
# that branch on the remote, and releases Archon's registration of the scratch
# clone as the target repository's codebase. After a merge there is no open
# pull request to close, and deleting the merged branch is still right.
#
# SLICE_E2E_CLONE_URL, when set, is the URL the suite clones SLICE_E2E_REPO
# from instead of gh's default, for a machine whose git credential for that
# URL belongs to a different account than gh's, which makes no-mistakes' push
# fail. gh still reaches the repository through SLICE_E2E_REPO, via GH_REPO
# and -R, so the clone URL can use any host alias git knows.
#
# SLICE_E2E_KEEP=1 keeps the scratch clone, the run log and Archon's worktree
# (when close has not already removed it) for inspection instead of removing
# them, leaves the pull request and its branch in place too, and leaves
# Archon's registration of the scratch clone in place. The live artifacts are
# more useful than a clean target while debugging a run.
#
# One run happens in setup_file, and each test below checks one fact about
# what it left behind. The checks read git, the tracker and the pull request
# directly, never the workflow's own report, because a workflow that reports
# success without having done the work is the failure this suite exists to
# catch.

TREE="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

# Prints the spec for bead $1. Small enough that the model spends its time on
# the pipeline rather than the problem, while still needing both code and a
# test, since verify only credits a commit that touches a test file. The file
# names carry the bead id because a green run merges them into the target.
spec_for() {
  # shellcheck disable=SC2016 # Backticks are Markdown for the model, not expansions.
  printf 'Add an executable greet-%s.sh at the repository root. `./greet-%s.sh <name>`
prints `hello, <name>` to stdout and exits 0. Run with no argument, it prints
a usage line to stderr and exits 2. Cover both behaviours with bats tests in
tests/greet-%s.bats, and commit the script and the tests together on the
current branch.' "$1" "$1" "$1"
}

setup_file() {
  [ "${SLICE_E2E:-}" = 1 ] || skip "set SLICE_E2E=1 to run the real pipeline"
  [ -n "${SLICE_E2E_REPO:-}" ] || skip "set SLICE_E2E_REPO=owner/name to a GitHub repository you can push to and open pull requests on"
  local tool
  for tool in archon bd bats git jq gh no-mistakes; do
    command -v "$tool" >/dev/null || skip "no $tool"
  done

  # The physical path, which is what Archon records, so teardown still matches
  # its registration if the scratch dir is gone by then and cannot be resolved.
  SCRATCH="$(mktemp -d)" && SCRATCH="$(cd "$SCRATCH" && pwd -P)" && [ -n "$SCRATCH" ] || {
    unset SCRATCH
    echo "# cannot create a scratch dir" >&3
    exit 1
  }
  export SCRATCH
  export REPO="$SCRATCH/repo" SOURCE="$SCRATCH/source" RUN_LOG="$SCRATCH/run.log"
  export ARCHON_SNAPSHOT="$SCRATCH/archon-codebases.sql"

  export GH_REPO="$SLICE_E2E_REPO"
  if [ -n "${SLICE_E2E_CLONE_URL:-}" ]; then
    git clone --quiet "$SLICE_E2E_CLONE_URL" "$REPO" >"$RUN_LOG" 2>&1
  else
    gh repo clone "$SLICE_E2E_REPO" "$REPO" -- --quiet >"$RUN_LOG" 2>&1
  fi || {
    echo "# cannot clone $SLICE_E2E_REPO; see $RUN_LOG" >&3
    exit 1
  }

  # Must run before anything writes into the clone or reaches the forge.
  require_e2e_sandbox "$SLICE_E2E_REPO" "$REPO" 2>&3 || {
    echo "# $SLICE_E2E_REPO is not a slice e2e sandbox; see above" >&3
    exit 1
  }

  # Repo-local, not GIT_CONFIG_GLOBAL as the other suites use: the model's
  # commit happens in Archon's worktree, which shares this config but not the
  # test's environment. An inherited commit.gpgsign would park that commit on
  # a signing prompt nobody answers.
  git -C "$REPO" config user.name "Slice E2E"
  git -C "$REPO" config user.email e2e@example.com
  git -C "$REPO" config commit.gpgsign false

  (cd "$REPO" && no-mistakes init) >>"$RUN_LOG" 2>&1 || {
    echo "# no-mistakes init failed on $SLICE_E2E_REPO; see $RUN_LOG" >&3
    exit 1
  }

  # Stealth keeps the tracker out of git status, so the model starts from a
  # clean tree.
  export BEADS_DIR="$REPO/.beads"
  (cd "$REPO" && bd init --non-interactive --stealth --prefix e2e >/dev/null 2>&1)
  BEAD="$(bd create --title "Add a greet script" --type task --priority 2 --silent)"
  export BEAD
  bd update "$BEAD" --design "$(spec_for "$BEAD")" >/dev/null
  BRANCH="$("$TREE/bin/slice-wave" branch-name "$BEAD")"
  export BRANCH

  # --workflow-source reads the workflow from a directory other than the repo
  # the run acts on. That is what lets this suite run the branch's workflow
  # against a scratch repo without installing anything. A copy under a pack
  # level, for the same reasons local-test.sh gives.
  mkdir -p "$SOURCE/.archon/workflows/slice-pipeline"
  cp -R "$TREE/workflows/implement-slice" "$SOURCE/.archon/workflows/slice-pipeline/"

  # Tells teardown that setup reached the run, so there may be a worktree,
  # branch or registration to undo. Unset, the target may be one the guard
  # refused, which teardown must not touch.
  export E2E_REACHED_RUN=1

  # Before the run, so teardown can tell a codebase row Archon rewrote to point
  # at the scratch clone from one the run created.
  snapshot_archon_registrations "$ARCHON_SNAPSHOT" 2>&3

  # This tree's bin first, so the nodes run the slice-wave under test rather
  # than whatever install.sh last linked onto the machine. In the background,
  # because the run waits in review for a send only this suite makes; nothing
  # skips review. fd 3 is closed on it so bats does not wait on the run. A
  # failed send would leave the run waiting through 20 rounds of 8 hours, so
  # the run and everything under it is killed instead.
  local rc=0 run_pid
  (cd "$REPO" && PATH="$TREE/bin:$PATH" archon workflow run implement-slice \
    --workflow-source "$SOURCE" --branch "e2e/$BEAD" \
    --input bead="$BEAD" --input beads_dir="$BEADS_DIR") >>"$RUN_LOG" 2>&1 3>&- &
  run_pid=$!
  send_empty_review "$BEAD" "$SLICE_E2E_REPO" "$run_pid" 2>&3 || stop_run "$run_pid"
  export REVIEW_TAB_TITLE REVIEW_HANDLE REVIEW_PR
  wait "$run_pid" || rc=$?
  export RUN_RC="$rc"

  RUN_ID="$(cd "$REPO" && archon workflow runs --json --limit 1 | jq -r '.runs[0].id // empty')"
  export RUN_ID

  # Read from merge, the returns node, whose parsed result the run record
  # keeps whole. merge passes validate's pr_number through on every verdict.
  # validate's node preview is cut at about 200 characters, which a long
  # repository name in its pr_url and repo fields pushes pr_number past.
  PR_NUMBER="$(run_json | jq -r '.terminal_record.returns.value.pr_number // empty')"
  export PR_NUMBER
}

teardown_file() {
  [ -n "${SCRATCH:-}" ] || return 0
  if [ "${SLICE_E2E_KEEP:-}" = 1 ]; then
    echo "# kept scratch at $SCRATCH (run log: $RUN_LOG, run: ${RUN_ID:-none}, pr: ${PR_NUMBER:-none}, review tab pane: ${REVIEW_HANDLE:-none})" >&3
    [ "${E2E_REACHED_RUN:-}" = 1 ] || return 0
    # The snapshot is copied out of the scratch dir so the release command
    # still works once the kept scratch dir is deleted.
    local snapshot
    snapshot="$(mktemp)" && cp "$ARCHON_SNAPSHOT" "$snapshot" || snapshot="$ARCHON_SNAPSHOT"
    echo "# Archon still registers the scratch clone as $SLICE_E2E_REPO's codebase; a later run from another clone fails until it is released, e.g. bash -c '. $TREE/tests/helpers/e2e-cleanup.bash; release_archon_registration $SCRATCH $snapshot'" >&3
    return 0
  fi
  # Setup can stop before the run at the clone, the sandbox guard, no-mistakes
  # init or bd, leaving no worktree, branch or registration to undo, and a
  # target the guard refused must not be touched at all.
  if [ "${E2E_REACHED_RUN:-}" = 1 ]; then
    close_review_tab "${REVIEW_HANDLE:-}" 2>&3
    (cd "$REPO" && archon complete "e2e/$BEAD" >/dev/null 2>&1) ||
      echo "# archon complete e2e/$BEAD failed; run 'archon isolation list' to find the worktree" >&3
    close_slice_branch "$SLICE_E2E_REPO" "${BRANCH:-}" "$REPO" 2>&3
    release_archon_registration "$SCRATCH" "$ARCHON_SNAPSHOT" 2>&3
  fi
  rm -rf "$SCRATCH"
}

run_json() {
  (cd "$REPO" && archon workflow get "$RUN_ID" "$@" --json)
}

# Printed when the run itself went wrong, so a red run explains itself without
# a rerun. The engine's JSON log lines are dropped; the node lines and the
# final verdict are what say which node failed and why.
diagnose() {
  echo "archon exited $RUN_RC; run ${RUN_ID:-none}; log $RUN_LOG" >&2
  grep -v '^{"level"' "$RUN_LOG" | tail -25 >&2
}

@test "the run reports the authored outcome succeeded" {
  [ -n "$RUN_ID" ] || { diagnose; exit 1; }
  outcome="$(run_json | jq -r '.outcome')"
  [ "$outcome" = succeeded ] || diagnose
  equals "$outcome" succeeded
}

@test "the run read its workflow from this tree, not an installed copy" {
  origin="$(run_json | jq -r '.metadata.workflow_source.origin')"
  equals "$origin" "$SOURCE"
}

@test "the slice branch carries a commit beyond origin/main that touches a test file" {
  git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" || {
    echo "no branch $BRANCH" >&2
    exit 1
  }
  count="$(git -C "$REPO" rev-list --count "origin/main..$BRANCH")"
  [ "$count" -gt 0 ] || { echo "no commit on $BRANCH beyond origin/main" >&2; exit 1; }
  contains "$(git -C "$REPO" diff --name-only "origin/main...$BRANCH")" "tests/greet-$BEAD.bats"
}

@test "the committed script does what the bead asked" {
  wt="$(mktemp -d)"
  git -C "$REPO" archive "$BRANCH" | tar -x -C "$wt"

  rc=0; out="$(cd "$wt" && "./greet-$BEAD.sh" world 2>/dev/null)" || rc=$?
  equals "$rc" 0
  equals "$out" "hello, world"

  rc=0; (cd "$wt" && "./greet-$BEAD.sh" >/dev/null 2>&1) || rc=$?
  equals "$rc" 2
  rm -rf "$wt"
}

@test "verify reported the sha the branch actually points at" {
  reported="$(run_json --verbose | jq -r '
    [.nodes[]? | select(.nodeId == "verify") | .outputPreview | fromjson? | .sha] | first // empty')"
  equals "$reported" "$(git -C "$REPO" rev-parse "$BRANCH")"
}

@test "the bead is closed" {
  status="$(bd show "$BEAD" --json | jq -r 'if type == "array" then .[0] else . end | .status')"
  equals "$status" closed
}

@test "the forge reports the pull request merged" {
  [ -n "$PR_NUMBER" ] && [ "$PR_NUMBER" -gt 0 ] 2>/dev/null || {
    echo "no pr_number in merge's return value; see $RUN_LOG" >&2
    exit 1
  }
  state="$(gh pr view "$PR_NUMBER" -R "$SLICE_E2E_REPO" --json state --jq .state)"
  equals "$state" MERGED
}

@test "no worktree is left on the slice branch" {
  lacks "$(git -C "$REPO" worktree list)" "[$BRANCH]"
}

@test "the findings record comment landed on the pull request" {
  [ -n "$PR_NUMBER" ] && [ "$PR_NUMBER" -gt 0 ] 2>/dev/null || {
    echo "no pr_number in merge's return value; see $RUN_LOG" >&2
    exit 1
  }
  record="$(gh api "repos/$SLICE_E2E_REPO/issues/$PR_NUMBER/comments" \
    --jq '[.[].body | select(startswith("<!-- slice-pipeline:findings-record -->"))] | last // empty')"
  [ -n "$record" ] || { echo "no findings record comment on PR $PR_NUMBER" >&2; exit 1; }
  contains "$record" "Drive mode: yes"
  printf '%s\n' "$record" | grep -Eq '^Outcome: (checks-passed|passed)$' || {
    printf 'the findings record names no green outcome:\n%s\n' "$record" >&2
    exit 1
  }
  lacks "$record" "Findings history: unknown"
  printf '%s\n' "$record" | grep -Eq '^(Ask-user findings|Findings history: none$)' || {
    printf 'the findings record carries no findings-history line:\n%s\n' "$record" >&2
    exit 1
  }
}

@test "a review tab titled for the bead and its pull request opened" {
  [ -n "${REVIEW_TAB_TITLE:-}" ] || { echo "Orca never showed a review tab for $BEAD; see $RUN_LOG" >&2; exit 1; }
  equals "$REVIEW_TAB_TITLE" "review $BEAD #$PR_NUMBER"
}

@test "the review's tuicr session released once or more, and its batch carried no comments" {
  [ -n "$PR_NUMBER" ] && [ "$PR_NUMBER" -gt 0 ] 2>/dev/null || {
    echo "no pr_number in validate's output; see $RUN_LOG" >&2
    exit 1
  }
  slug="gh:$SLICE_E2E_REPO/pr/$PR_NUMBER"
  releases="$(tuicr review list --repo "$SLICE_E2E_REPO" | jq -r --arg slug "$slug" '[.[] | select(.slug == $slug) | .release_count] | first // empty')"
  [ -n "$releases" ] || { echo "tuicr holds no session $slug" >&2; exit 1; }
  [ "$releases" -ge 1 ] || { echo "session $slug released $releases times" >&2; exit 1; }
  sent="$(tuicr review comments --session "$slug" | jq '[.[] | select(.released_in != null)] | length')"
  equals "$sent" 0
}
