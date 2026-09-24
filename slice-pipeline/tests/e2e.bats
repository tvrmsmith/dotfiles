load helpers/assert

# The one suite that runs the real pipeline: a real GitHub target, this tree's
# workflow under the real engine, and a real model building a real bead. The
# other suites each stub out a layer (slice-wave.bats the engine, the
# fixtures the script, the wiring suite the model), so only this one shows
# that the five nodes - claim, build, verify, validate, release - hand off to
# each other for real, against a repository claim's own preflight checks
# actually have to accept.
#
# claim now refuses a target it cannot open pull requests on or that
# no-mistakes has never validated (see check_target_forge and
# check_target_no_mistakes in bin/slice-wave), so the scratch repo the old
# version of this suite built - a local bare origin, never run through
# `no-mistakes init` - no longer clears claim and cannot stand in for a real
# target. This version clones a real repository instead.
#
# Opt-in, because a run spends model tokens, pushes a branch and opens a pull
# request on a real repository, and can go red on a bad model run rather than
# on broken code:
#
#   SLICE_E2E=1 SLICE_E2E_REPO=owner/name bats slice-pipeline/tests/e2e.bats
#
# SLICE_E2E_REPO names a GitHub repository (owner/name) you can push to and
# open pull requests on; the suite skips with a clear message when it is
# unset. It clones that repository to scratch, runs `no-mistakes init` there
# so claim's preflight passes, then drives one small bead through the real
# pipeline: claim, a real model build, verify, a real no-mistakes validate
# drive against that repository's forge, and release. Teardown closes the
# pull request the drive opened and deletes its remote branch, so a run
# leaves the target repository exactly as it found it, aside from a closed,
# branch-deleted pull request.
#
# SLICE_E2E_KEEP=1 keeps the scratch clone, the run log and Archon's worktree
# for inspection instead of removing them, and leaves the pull request and its
# branch open too - the live artifacts are more useful than a clean target
# while debugging a run.
#
# One run happens in setup_file, and each test below checks one fact about
# what it left behind. The checks read git, the tracker and the pull request
# directly, never the workflow's own report, because a workflow that reports
# success without having done the work is the failure this suite exists to
# catch.

TREE="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

# Small enough that the model spends its time on the pipeline rather than the
# problem, while still needing both code and a test, since verify only credits
# a commit that touches a test file.
# shellcheck disable=SC2016 # Backticks are Markdown for the model, not expansions.
SPEC='Add an executable greet.sh at the repository root. `./greet.sh <name>`
prints `hello, <name>` to stdout and exits 0. Run with no argument, it prints
a usage line to stderr and exits 2. Cover both behaviours with bats tests in
tests/greet.bats, and commit the script and the tests together on the
current branch.'

setup_file() {
  [ "${SLICE_E2E:-}" = 1 ] || skip "set SLICE_E2E=1 to run the real pipeline"
  [ -n "${SLICE_E2E_REPO:-}" ] || skip "set SLICE_E2E_REPO=owner/name to a GitHub repository you can push to and open pull requests on"
  local tool
  for tool in archon bd bats git jq gh no-mistakes; do
    command -v "$tool" >/dev/null || skip "no $tool"
  done

  SCRATCH="$(mktemp -d)"
  export SCRATCH
  export REPO="$SCRATCH/repo" SOURCE="$SCRATCH/source" RUN_LOG="$SCRATCH/run.log"

  gh repo clone "$SLICE_E2E_REPO" "$REPO" -- --quiet >"$RUN_LOG" 2>&1 || {
    echo "# cannot clone $SLICE_E2E_REPO; see $RUN_LOG" >&3
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
  BEAD="$(bd create --title "Add a greet script" --type task --priority 2 \
    --design "$SPEC" --silent)"
  export BEAD
  BRANCH="$("$TREE/bin/slice-wave" branch-name "$BEAD")"
  export BRANCH

  # --workflow-source reads the workflow from a directory other than the repo
  # the run acts on. That is what lets this suite run the branch's workflow
  # against a scratch repo without installing anything. A copy under a pack
  # level, for the same reasons local-test.sh gives.
  mkdir -p "$SOURCE/.archon/workflows/slice-pipeline"
  cp -R "$TREE/workflows/implement-slice" "$SOURCE/.archon/workflows/slice-pipeline/"

  # This tree's bin first, so the nodes run the slice-wave under test rather
  # than whatever install.sh last linked onto the machine.
  local rc=0
  (cd "$REPO" && PATH="$TREE/bin:$PATH" archon workflow run implement-slice \
    --workflow-source "$SOURCE" --branch "e2e/$BEAD" \
    --input bead="$BEAD" --input beads_dir="$BEADS_DIR") >>"$RUN_LOG" 2>&1 || rc=$?
  export RUN_RC="$rc"

  RUN_ID="$(cd "$REPO" && archon workflow runs --json --limit 1 | jq -r '.runs[0].id // empty')"
  export RUN_ID

  # validate's own output_format is the one place a pull request number
  # appears; found the same way verify's sha is below, since the node's
  # output can sit at any depth in --verbose's tree depending on how the
  # engine nests a returns node's result.
  PR_NUMBER="$(run_json --verbose | jq -r \
    '[.. | objects | select(.pr_number? != null and .record_posted? != null) | .pr_number] | first // empty')"
  export PR_NUMBER
}

teardown_file() {
  [ -n "${SCRATCH:-}" ] || return 0
  if [ "${SLICE_E2E_KEEP:-}" = 1 ]; then
    echo "# kept scratch at $SCRATCH (run log: $RUN_LOG, run: ${RUN_ID:-none}, pr: ${PR_NUMBER:-none})" >&3
    return 0
  fi
  (cd "$REPO" && archon complete "e2e/$BEAD" >/dev/null 2>&1) ||
    echo "# archon complete e2e/$BEAD failed; run 'archon isolation list' to find the worktree" >&3
  if [ -n "${PR_NUMBER:-}" ] && [ "$PR_NUMBER" -gt 0 ] 2>/dev/null; then
    (cd "$REPO" && gh pr close "$PR_NUMBER" -R "$SLICE_E2E_REPO" --delete-branch >/dev/null 2>&1) ||
      echo "# gh pr close $PR_NUMBER --delete-branch failed on $SLICE_E2E_REPO; close and delete $BRANCH by hand" >&3
  else
    echo "# no pr_number from validate; nothing to close on $SLICE_E2E_REPO" >&3
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
  contains "$(git -C "$REPO" diff --name-only "origin/main...$BRANCH")" "tests/greet.bats"
}

@test "the committed script does what the bead asked" {
  wt="$(mktemp -d)"
  git -C "$REPO" archive "$BRANCH" | tar -x -C "$wt"

  rc=0; out="$(cd "$wt" && ./greet.sh world 2>/dev/null)" || rc=$?
  equals "$rc" 0
  equals "$out" "hello, world"

  rc=0; (cd "$wt" && ./greet.sh >/dev/null 2>&1) || rc=$?
  equals "$rc" 2
  rm -rf "$wt"
}

@test "verify reported the sha the branch actually points at" {
  reported="$(run_json --verbose | jq -r '
    [.. | objects | select(.verified? != null and .sha? != null) | .sha] | first // empty')"
  equals "$reported" "$(git -C "$REPO" rev-parse "$BRANCH")"
}

@test "a landed slice keeps its claim instead of going back on the ready list" {
  bead_json="$(bd show "$BEAD" --json)"
  equals "$(printf '%s' "$bead_json" | jq -r 'if type == "array" then .[0] else . end | .status')" in_progress
  lacks "$(bd ready --json | jq -r '.[]?.id')" "$BEAD"
}

@test "the findings record comment landed on the pull request" {
  [ -n "$PR_NUMBER" ] && [ "$PR_NUMBER" -gt 0 ] 2>/dev/null || {
    echo "no pr_number in validate's output; see $RUN_LOG" >&2
    exit 1
  }
  record="$(gh api "repos/$SLICE_E2E_REPO/issues/$PR_NUMBER/comments" \
    --jq '[.[].body | select(startswith("<!-- slice-pipeline:findings-record -->"))] | last // empty')"
  [ -n "$record" ] || { echo "no findings record comment on PR $PR_NUMBER" >&2; exit 1; }
  contains "$record" "Drive mode: yes"
  contains "$record" "Outcome: "
  printf '%s\n' "$record" | grep -Eq '^(Ask-user findings|Findings history: )' || {
    printf 'the findings record carries no findings-history line:\n%s\n' "$record" >&2
    exit 1
  }
}
