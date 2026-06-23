load helpers/setup
setup() {
  _mysbx_test_setup
  export STUB_DOCKER_LOG="$TMP/docker.log"; : > "$STUB_DOCKER_LOG"
}
teardown() { _mysbx_test_teardown; }

@test "build verb is handled locally, not forwarded to sbx as 'build'" {
  ( cd "$TMP" && zsh "$MYSBX" build claude-sandbox-mise )
  # real sbx never receives a literal 'build' verb
  ! grep -qx build "$STUB_SBX_LOG"
  # docker compose build was invoked
  grep -q 'compose' "$STUB_DOCKER_LOG"
}

@test "omp-clean verb handled locally" {
  run zsh -c "cd '$TMP' && '$MYSBX' omp-clean"
  [ "$status" -eq 0 ]
  ! grep -qx omp-clean "$STUB_SBX_LOG"
}

@test "secrets-sync verb syncs without forwarding" {
  ( cd "$TMP" && zsh "$MYSBX" secrets-sync mybox )
  grep -qx github "$STUB_SBX_LOG"
  ! grep -qx secrets-sync "$STUB_SBX_LOG"
}
