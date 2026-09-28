load helpers/assert
load helpers/stubs

# Binds the two halves of every exec node together. `slice-wave.bats` runs the
# script with the workflow absent and `archon workflow test` stubs the bodies
# away, so each suite passes while the other side drifts. These tests take the
# command line the workflow actually declares, run it the way the engine runs
# it, and hold the real output to the real declared output_format.

WORKFLOW="${BATS_TEST_DIRNAME}/../workflows/implement-slice/implement-slice.yaml"
NODE="${BATS_TEST_DIRNAME}/helpers/workflow-node.ts"
EXEC_NODES="claim verify release validate merge close"

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
# `pr_number`, `repo` and `pr_url` need a number, a slug and a URL for the
# script to accept them, and every other field this workflow substitutes is a
# boolean, so `true`. Any further argument, `field=value`, overrides one
# field's value, written the way Archon writes it into a bash body: shell
# quoted, so an empty string arrives as ''.
run_node_body() {
  local node="$1" body token field value override
  shift
  body="$(bun "$NODE" body "$WORKFLOW" "$node")" || return 2
  while token="$(printf '%s' "$body" | grep -oE '\$[A-Za-z_][A-Za-z0-9_]*\.output\.[A-Za-z_][A-Za-z0-9_]*' | head -n 1)" && [ -n "$token" ]; do
    field="${token##*.}"
    case "$field" in
      pr_number) value=42 ;;
      repo) value=owner/repo ;;
      pr_url) value=https://github.com/owner/repo/pull/42 ;;
      *) value=true ;;
    esac
    for override in "$@"; do
      [ "${override%%=*}" != "$field" ] || value="${override#*=}"
    done
    body="${body%%"$token"*}${value}${body#*"$token"}"
  done
  ( cd "$REPO" && env INPUTS_BEAD=foo INPUTS_BEADS_DIR="$STUB_BIN" sh -c "$body" )
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

# validate's short-circuit on an unverified slice reports no pull request and
# no repository, and merge runs on that path too, with no `when:`. A merge
# body that rejected those values would fail the node and skip release,
# leaving the bead claimed.
@test "the merge node prints what the workflow declares on validate's undelivered output" {
  rc=0; out="$(run_node_body merge delivered=false pr_number=0 "repo=''")" || rc=$?
  equals "$rc" 0
  printf '%s' "$out" | bun "$NODE" check-output "$WORKFLOW" merge
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
