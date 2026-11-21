# Each @test runs in its own subshell, so the stub knobs a test exports are
# meant to stay local to it.
# shellcheck disable=SC2030,SC2031
load helpers/assert
load helpers/stubs

# Binds the two halves of every exec node together. `slice-wave.bats` runs the
# script with the workflow absent and `archon workflow test` stubs the bodies
# away, so each suite passes while the other side drifts. These tests take the
# command line the workflow actually declares, run it the way the engine runs
# it, and hold the real output to the real declared output_format.

WORKFLOW="${BATS_TEST_DIRNAME}/../workflows/implement-slice/implement-slice.yaml"
NODE="${BATS_TEST_DIRNAME}/helpers/workflow-node.ts"
EXEC_NODES="claim verify release validate review-round merge close"

setup() {
  command -v bun >/dev/null || skip "no bun"
  command -v jq >/dev/null || skip "no jq"

  # See slice-wave.bats: an inherited commit.gpgsign hangs the scratch-repo
  # commit below rather than failing it.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  STUB_BIN="$(mktemp -d)"
  export STUB_BIN
  export FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures/axi"
  install_stubs

  # See merge-and-close.bats: the merge body must not read the machine's
  # real repos.json, and its poll must not sleep.
  export XDG_CONFIG_HOME="$STUB_BIN/config"
  export SLICE_WAVE_MERGE_POLL_SECONDS=0

  OLD_PATH="$PATH"
  # The workflow invokes a bare `slice-wave`, so this tree's copy has to be the
  # one that resolves. Putting it here rather than relying on the link
  # install.sh makes is also what keeps this suite testing the tree it ships
  # with, not whatever version is currently installed on the machine.
  export PATH="${BATS_TEST_DIRNAME}/../bin:$STUB_BIN:$PATH"

  REPO="$(mktemp -d)"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test \
    commit --quiet --allow-empty -m base

  ORIGIN="$(mktemp -d)"
  git init --quiet --bare "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN"
}

teardown() {
  export PATH="$OLD_PATH"
  rm -rf "$STUB_BIN" "$REPO" "$ORIGIN"
}

# Runs $1's declared body the way the engine does: under `sh`, with the run's
# declared inputs arriving as INPUTS_<UPPER_SNAKE> environment variables and
# every $<node>.output.<field> token pre-substituted, the way Archon
# substitutes a producer node's declared output into a downstream body before
# running it. Each field gets a representative value of its own type:
# `pr_number`, `repo`, `pr_url` and `head_sha` need a number, a slug, a URL
# and a 40-hex commit (the gh stub's head) for the script to accept them, and
# every other field this workflow substitutes is a boolean, `approved` and
# `delivered` among them, so `true`. A $LOOP_PREV.<node>.output.<field> token
# renders as '', as it does on a loop's first iteration, unless a
# `LOOP_PREV=<json>` argument supplies the previous iteration's outputs keyed
# by node id, whose field it then renders shell quoted once <node> declares
# it. $WORKFLOW_ID arrives as run-1. Any further argument, `field=value`,
# overrides one field's value, written the way Archon writes it into a bash
# body: shell quoted, so an empty string arrives as ''.
run_node_body() {
  local node="$1" body token field value override prev="" producer
  shift
  for override in "$@"; do
    [ "${override%%=*}" != LOOP_PREV ] || prev="${override#*=}"
  done
  body="$(bun "$NODE" body "$WORKFLOW" "$node")" || return 2
  # shellcheck disable=SC2016 # A literal Archon token, not an expansion.
  while token="$(printf '%s' "$body" | grep -oE '\$LOOP_PREV\.[A-Za-z_][A-Za-z0-9_-]*\.output\.[A-Za-z_][A-Za-z0-9_]*' | head -n 1)" && [ -n "$token" ]; do
    value="''"
    if [ -n "$prev" ]; then
      producer="${token#*.}"
      producer="${producer%%.*}"
      field="${token##*.}"
      bun "$NODE" properties "$WORKFLOW" "$producer" | grep -qxF "$field" || {
        echo "$token names a field node $producer does not declare" >&2
        return 2
      }
      value="'$(printf '%s' "$prev" | jq -r --arg node "$producer" --arg field "$field" '.[$node][$field] // ""')'"
    fi
    body="${body%%"$token"*}${value}${body#*"$token"}"
  done
  while token="$(printf '%s' "$body" | grep -oE '\$[A-Za-z_][A-Za-z0-9_-]*\.output\.[A-Za-z_][A-Za-z0-9_]*' | head -n 1)" && [ -n "$token" ]; do
    field="${token##*.}"
    case "$field" in
      pr_number) value=42 ;;
      repo) value=owner/repo ;;
      pr_url) value=https://github.com/owner/repo/pull/42 ;;
      head_sha) value=0123456789abcdef0123456789abcdef01234567 ;;
      *) value=true ;;
    esac
    for override in "$@"; do
      [ "${override%%=*}" != "$field" ] || value="${override#*=}"
    done
    body="${body%%"$token"*}${value}${body#*"$token"}"
  done
  ( cd "$REPO" && env INPUTS_BEAD=foo INPUTS_BEADS_DIR="$STUB_BIN" WORKFLOW_ID=run-1 sh -c "$body" )
}

@test "the claim node prints what the workflow declares it prints" {
  rc=0; out="$(run_node_body claim)" || rc=$?
  equals "$rc" 0
  printf '%s' "$out" | bun "$NODE" check-output "$WORKFLOW" claim
}

@test "the verify node prints what the workflow declares it prints" {
  rc=0; out="$(run_node_body verify)" || rc=$?
  equals "$rc" 0
  printf '%s' "$out" | bun "$NODE" check-output "$WORKFLOW" verify
}

@test "the release node prints what the workflow declares it prints" {
  rc=0; out="$(run_node_body release)" || rc=$?
  equals "$rc" 0
  printf '%s' "$out" | bun "$NODE" check-output "$WORKFLOW" release
}

@test "the validate node prints what the workflow declares it prints" {
  rc=0; out="$(run_node_body validate)" || rc=$?
  equals "$rc" 0
  printf '%s' "$out" | bun "$NODE" check-output "$WORKFLOW" validate
}

@test "the merge node prints what the workflow declares it prints" {
  rc=0; out="$(run_node_body merge)" || rc=$?
  equals "$rc" 0
  printf '%s' "$out" | bun "$NODE" check-output "$WORKFLOW" merge
}

# Every unapproved review reports no head, and an undelivered slice no pull
# request and no repository either, and merge runs on those paths too, with no
# `when:`. A merge body that rejected those values would fail the node and
# skip release, leaving the bead claimed.
@test "the merge node prints what the workflow declares on review's unapproved output" {
  rc=0; out="$(run_node_body merge approved=false "head_sha=''" pr_number=0 "repo=''")" || rc=$?
  equals "$rc" 0
  printf '%s' "$out" | bun "$NODE" check-output "$WORKFLOW" merge
}

# A first round, before the gate has an answer, opens the review tab and
# hands the gate its question with the pull request's head.
@test "the review-round node prints what the workflow declares it prints" {
  export GH_PR_VIEW_STATES=OPEN
  rc=0; out="$(run_node_body review-round)" || rc=$?
  equals "$rc" 0
  equals "$(printf '%s' "$out" | jq -r .outcome)" waiting
  equals "$(printf '%s' "$out" | jq -r .head_sha)" 0123456789abcdef0123456789abcdef01234567
  printf '%s' "$out" | bun "$NODE" check-output "$WORKFLOW" review-round
}

# The gate's approval reaches the next round through $LOOP_PREV, which turns
# it into the approved head merge reads.
@test "the review loop's next round approves the head the gate's answer names" {
  export GH_PR_VIEW_STATES=OPEN
  prev="$(run_node_body review-round)"
  head=fedcba9876543210fedcba9876543210fedcba98
  loop_prev="$(jq -cn --argjson round "$prev" --arg head "$head" \
    '{"review-round": $round, "review-gate": {decision: "approved", text: $head}}')"
  rc=0; out="$(run_node_body review-round "LOOP_PREV=$loop_prev")" || rc=$?
  equals "$rc" 0
  equals "$(printf '%s' "$out" | jq -r .outcome)" approved
  equals "$(printf '%s' "$out" | jq -r .head_sha)" "$head"
  printf '%s' "$out" | bun "$NODE" check-output "$WORKFLOW" review-round
}

# An approval answered by hand with no text approves the head the last
# round's question showed.
@test "the review loop's next round approves the shown head on an approval with no text" {
  export GH_PR_VIEW_STATES=OPEN
  prev="$(run_node_body review-round)"
  loop_prev="$(jq -cn --argjson round "$prev" \
    '{"review-round": $round, "review-gate": {decision: "approved", text: ""}}')"
  rc=0; out="$(run_node_body review-round "LOOP_PREV=$loop_prev")" || rc=$?
  equals "$rc" 0
  equals "$(printf '%s' "$out" | jq -r .head_sha)" 0123456789abcdef0123456789abcdef01234567
}

@test "the review loop's next round waits again after comments" {
  export GH_PR_VIEW_STATES=OPEN
  prev="$(run_node_body review-round)"
  loop_prev="$(jq -cn --argjson round "$prev" \
    '{"review-round": $round, "review-gate": {decision: "comments", text: "2 comments sent in release 3"}}')"
  rc=0; out="$(run_node_body review-round "LOOP_PREV=$loop_prev")" || rc=$?
  equals "$rc" 0
  equals "$(printf '%s' "$out" | jq -r .outcome)" waiting
}

# Every slice passes through review, so review-round runs on validate's
# undelivered output too, and has to accept its empty repository and zero
# pull request.
@test "the review-round node prints what the workflow declares on validate's undelivered output" {
  rc=0; out="$(run_node_body review-round delivered=false pr_number=0 "repo=''")" || rc=$?
  equals "$rc" 0
  printf '%s' "$out" | bun "$NODE" check-output "$WORKFLOW" review-round
}

# Runs loop group $1's declared until_bash the way the engine does, under
# `bash -c` after an iteration, with each $<node>.output.<field> token
# replaced by $2 shell quoted, as Archon substitutes a string output there.
# `archon workflow test` never runs until_bash, so this is the only check that
# the loop ends where the workflow means it to.
run_until_bash() {
  local body token
  body="$(bun "$NODE" until "$WORKFLOW" "$1")" || return 2
  while token="$(printf '%s' "$body" | grep -oE '\$[A-Za-z_][A-Za-z0-9_-]*\.output\.[A-Za-z_][A-Za-z0-9_]*' | head -n 1)" && [ -n "$token" ]; do
    body="${body%%"$token"*}'$2'${body#*"$token"}"
  done
  bash -c "$body"
}

# An undelivered slice's loop that did not end here would run 20 rounds, fail
# review, and skip release, leaving the bead claimed.
@test "the review loop ends on the round an undelivered slice reports" {
  out="$(run_node_body review-round delivered=false pr_number=0 "repo=''")"
  rc=0; run_until_bash review "$(printf '%s' "$out" | jq -r .outcome)" || rc=$?
  equals "$rc" 0
}

@test "the review loop ends on an approving round" {
  rc=0; run_until_bash review approved || rc=$?
  equals "$rc" 0
}

@test "the review loop runs another round while the gate waits" {
  rc=0; run_until_bash review waiting || rc=$?
  equals "$rc" 1
}

@test "the close node prints what the workflow declares it prints" {
  rc=0; out="$(run_node_body close)" || rc=$?
  equals "$rc" 0
  printf '%s' "$out" | bun "$NODE" check-output "$WORKFLOW" close
}

@test "every exec node reads its inputs as env vars, not the prompt-only form" {
  # `$INPUTS.<name>` is substituted on a prompt surface but not into a shell
  # body, where it reaches sh as the empty string followed by a literal dot.
  for node in $EXEC_NODES; do
    body="$(bun "$NODE" body "$WORKFLOW" "$node")"
    # shellcheck disable=SC2016
    lacks "$body" '$INPUTS.'
  done
}

@test "every exec node body resolves to an executable on PATH" {
  for node in $EXEC_NODES; do
    body="$(bun "$NODE" body "$WORKFLOW" "$node")"
    command -v "${body%% *}" >/dev/null || {
      echo "node $node invokes '${body%% *}', which is not on PATH" >&2
      exit 1
    }
  done
}

@test "the build prompt files follow-ups under the slice's parent, not the slice" {
  # A child of the slice bead is never dispatched, since a wave lists only its
  # parent's direct children, and while it stays open `bd close` refuses the
  # slice after merge. The rule has to reach the agent, so it lives in the
  # prompt the build node renders, not only in docs.
  prompt="$(bun "$NODE" prompt "$WORKFLOW" build)"
  contains "$prompt" '.parent'
  contains "$prompt" '--parent'
  contains "$prompt" 'never as a child of $INPUTS.bead'
}
