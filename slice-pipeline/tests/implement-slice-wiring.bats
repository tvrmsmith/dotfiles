load helpers/assert

# Binds the two halves of every exec node together. `slice-wave.bats` runs the
# script with the workflow absent and `archon workflow test` stubs the bodies
# away, so each suite passes while the other side drifts. These tests take the
# command line the workflow actually declares, run it the way the engine runs
# it, and hold the real output to the real declared output_format.

WORKFLOW="${BATS_TEST_DIRNAME}/../workflows/implement-slice/implement-slice.yaml"
NODE="${BATS_TEST_DIRNAME}/helpers/workflow-node.ts"
EXEC_NODES="claim verify release"

setup() {
  command -v bun >/dev/null || skip "no bun"
  command -v jq >/dev/null || skip "no jq"

  STUB_BIN="$(mktemp -d)"
  export BD_LOG="$STUB_BIN/bd.log"
  : > "$BD_LOG"
  cat > "$STUB_BIN/bd" <<'EOF'
#!/bin/bash
printf '%s\t%s\n' "${BEADS_DIR:-}" "$*" >> "$BD_LOG"
exit "${BD_EXIT_CODE:-0}"
EOF
  chmod +x "$STUB_BIN/bd"

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
}

teardown() {
  export PATH="$OLD_PATH"
  rm -rf "$STUB_BIN" "$REPO"
}

# Runs $1's declared body the way the engine does: under `sh`, with the run's
# declared inputs arriving as INPUTS_<UPPER_SNAKE> environment variables.
run_node_body() {
  local body
  body="$(bun "$NODE" body "$WORKFLOW" "$1")" || return 2
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
